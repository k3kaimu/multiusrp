module receiver;

import core.time;
import core.thread;

import std.algorithm : min, canFind;
import std.sumtype;
import std.complex;
import std.stdio;
import std.math;
import std.experimental.allocator;
import std.typecons;

import utils;
import msgqueue;

import lock_free.rwqueue;

import uhd.usrp;
import uhd.capi;
import uhd.utils;


struct RxRequestTypes(C)
{
    static struct ChangeAlignSize
    {
        size_t newAlign;
    }


    static struct Skip
    {
        size_t delaySize;
    }


    static struct Receive
    {
        C[][] buffer;
    }


    static struct SyncToPPS
    {
        size_t myIndex;
        shared(bool)[] isReady;
    }


    static struct ApplyFilter
    {
        bool delegate(C[][]) fn;
    }


    static struct ClearCmdQueue {}
}


struct RxResponseTypes(C)
{
    static struct Receive
    {
        C[][] buffer;
    }
}


alias RxRequest(C) = SumType!(RxRequestTypes!C.ChangeAlignSize, RxRequestTypes!C.Skip, RxRequestTypes!C.Receive, RxRequestTypes!C.SyncToPPS, RxRequestTypes!C.ApplyFilter, RxRequestTypes!C.ClearCmdQueue);
alias RxResponse(C) = SumType!(RxResponseTypes!C.Receive);



void receive_worker(C, Alloc)(
    ref shared bool stop_signal_called,
    ref Alloc alloc,
    ref USRP usrp,
    size_t nRXUSRP,
    string cpu_format,
    string wire_format,
    bool time_sync,
    immutable(size_t)[] rx_channel_nums,
    float settling_time,
    size_t alignSize,
    UniqueMsgQueue!(RxRequest!C, RxResponse!C).Executer rxMsgQueue,
)
{
    alias dbg = debugMsg!"receive_worker";

    scope(exit) {
        dbg.writeln("END receive_worker");
    }

    C[][] nullBuffers;
    foreach(i; 0 .. nRXUSRP) nullBuffers ~= null;

    int num_total_samps = 0;
    //create a receive streamer
    dbg.writeln("CPU_FORMAT: ", cpu_format);
    dbg.writeln("WIRE_FORMAT: ", wire_format);
    StreamArgs stream_args = StreamArgs(cpu_format, wire_format, "", rx_channel_nums);
    RxStreamer rx_stream = usrp.makeRxStreamer(stream_args);

    // Prepare buffers for received samples and metadata
    RxMetaData md = makeRxMetaData();
    C[][] receiveBuffers = alloc.makeMultidimensionalArray!C(nRXUSRP, alignSize);
    scope(exit) {
        alloc.disposeMultidimensionalArray(receiveBuffers);
    }

    bool overflow_message = true;
    float timeout = settling_time + 0.1f; //expected settling time + padding for first recv

    //setup streaming
    if(time_sync)
        usrp.setTimeUnknownPPS(0.seconds);
    else
        usrp.setTimeNow(0.seconds);

    StreamCommand stream_cmd = StreamCommand.startContinuous;
    stream_cmd.streamNow = /*rx_channel_nums.length == 1 ? true : */ false;
    stream_cmd.timeSpec = (cast(long)floor(settling_time*1E6)).usecs;
    rx_stream.issue(stream_cmd);

    static struct RequestInfo {
        bool haveRequest;
        bool isProceeded;
        RxRequest!C req;
        RxRequestTypes!C.Receive rxReq;
        shared(C)[][] reqBuffers;

        void initialize() {
            haveRequest = false;
            isProceeded = false;
            req = typeof(req).init;
            rxReq = typeof(rxReq).init;
            foreach(ref e; reqBuffers)
                e = null;
        }
    }
    RequestInfo reqInfo;
    reqInfo.reqBuffers = new shared(C)[][](nRXUSRP);


    // fillBufferの内部で利用する
    C[][] _tmpbuffers = alloc.makeArray!(C[])(nRXUSRP);
    scope(exit) alloc.dispose(_tmpbuffers);

    Nullable!VUHDException fillBuffer(C[][] buffer, size_t maxSamples = size_t.max)
    in {
        assert(buffer.length == nRXUSRP);
        foreach(i; 0 .. nRXUSRP)
            assert(buffer[i].length == buffer[0].length);
    }
    do {
        scope(exit) foreach(i; 0 .. nRXUSRP) _tmpbuffers[i] = null;

        size_t numTotalSamples = 0;
        while(numTotalSamples < min(buffer[0].length, maxSamples)) {
            foreach(i; 0 .. nRXUSRP)
                _tmpbuffers[i] = buffer[i][numTotalSamples .. min($, maxSamples)];

            size_t num_rx_samps;
            if(auto err = rx_stream.recv(_tmpbuffers, md, timeout, num_rx_samps)){
                return typeof(return)(err);
            }

            if(num_rx_samps == 0)
                dbg.writeln("?");

            numTotalSamples += num_rx_samps;
        }

        return typeof(return).init;
    }


    // フィルター
    bool delegate(C[][]) filterFunc;


    VUHDException error;
    () {
        Lnextreceive: while(! stop_signal_called) {

            if(!rxMsgQueue.emptyRequest) {
                // キューにClearCmdQueueがあれば，全てのキューに入っているコマンドを消す
                bool isClear = rxMsgQueue.allRequestList.canFind!(a => a.match!((RxRequestTypes!C.ClearCmdQueue q) => true, _ => false));
                while(isClear && !rxMsgQueue.emptyRequest)
                    rxMsgQueue.popRequest();
            }

            // リクエストの処理をする
            while(! rxMsgQueue.emptyRequest && !reqInfo.haveRequest) {
                auto req = cast()rxMsgQueue.popRequest();
                dbg.writeln("POP Request!");
                req.match!(
                    (RxRequestTypes!C.Receive r) {
                        dbg.writeln("POP Receive Request!");
                        reqInfo.haveRequest = true;
                        reqInfo.req = req;
                        reqInfo.rxReq = r;
                        foreach(i; 0 .. nRXUSRP)
                            reqInfo.reqBuffers[i] = cast(shared)r.buffer[i];
                    },
                    (RxRequestTypes!C.ChangeAlignSize r) {
                        dbg.writefln("POP ChangeAlignSize(%s)!", r.newAlign);

                        if(alignSize != r.newAlign) {
                            alignSize = r.newAlign;
                            // 古いreceiveBuffersは破棄する
                            alloc.disposeMultidimensionalArray(receiveBuffers);

                            // alignSizeの新しいreceiveBuffersを作る
                            receiveBuffers = alloc.makeMultidimensionalArray!C(nRXUSRP, alignSize);
                        }
                    },
                    (RxRequestTypes!C.Skip r) {
                        dbg.writefln("POP Skip(%s)!", r.delaySize);
                        size_t totdelay = r.delaySize;
                        while(totdelay > 0) {
                            immutable size_t d = min(totdelay, alignSize);
                            fillBuffer(receiveBuffers, d);
                            totdelay -= d;
                        }
                    },
                    (RxRequestTypes!C.SyncToPPS r){
                        import core.atomic;
                        scope(exit) {
                            if(r.myIndex == 0)
                                alloc.dispose(cast(void[])r.isReady);
                        }

                        // shutdown receiver
                        rx_stream.issue(StreamCommand.stopContinuous);

                        // バッファの残りを受け取る
                        while(1) {
                            foreach(i; 0 .. nRXUSRP)
                                _tmpbuffers[i] = receiveBuffers[i];

                            size_t num_rx_samps;
                            rx_stream.recv(_tmpbuffers, md, timeout, num_rx_samps);
                            if(num_rx_samps == 0)
                                break;
                        }

                        dbg.writeln("Ready sync and wait other threads...");
                        // 自分は準備完了したことを他のスレッドに伝える
                        atomicStore(r.isReady[r.myIndex], true);

                        // 他のスレッドがすべて準備完了するまでwhileで待つ
                        while(1) {
                            bool check = true;
                            foreach(ref b; r.isReady)
                                check = check && atomicLoad(b);

                            if(check)
                                break;
                        }

                        // setup streaming
                        if(time_sync)
                            usrp.setTimeUnknownPPS(0.seconds);
                        else
                            usrp.setTimeNow(0.seconds);

                        StreamCommand stream_cmd = StreamCommand.startContinuous;
                        stream_cmd.streamNow = /*rx_channel_nums.length == 1 ? true : */ false;
                        stream_cmd.timeSpec = (cast(long)floor(settling_time*1E6)).usecs;
                        rx_stream.issue(stream_cmd);
                    },
                    (RxRequestTypes!C.ApplyFilter r) {
                        filterFunc = r.fn;
                    },
                    (RxRequestTypes!C.ClearCmdQueue) {
                        while(!rxMsgQueue.emptyRequest)
                            rxMsgQueue.popRequest();
                    }
                )();
            }


            // 受信をする
            {
                auto err = fillBuffer(receiveBuffers);
                if(!err.isNull) {
                    error = err.get;
                    return;
                }
            }
            timeout = 0.1f; //small timeout for subsequent recv

            md.ErrorCode errorCode;
            if(auto uhderr = md.getErrorCode(errorCode)){
                error = uhderr;
                Thread.sleep(2.seconds);
                receive_worker!C(stop_signal_called, alloc, usrp, nRXUSRP, cpu_format, wire_format, time_sync, rx_channel_nums, settling_time, alignSize, rxMsgQueue);
            }
            if (errorCode == md.ErrorCode.TIMEOUT) {
                import core.stdc.stdio : puts;
                puts("Timeout while streaming");
                break;
            }
            if (errorCode == md.ErrorCode.OVERFLOW) {
                if (overflow_message){
                    import core.stdc.stdio : fprintf, stderr;
                    overflow_message = false;
                    fprintf(stderr, "Got an overflow indication.");
                }
                continue;
            }
            if (errorCode != md.ErrorCode.NONE) {
                import core.stdc.stdio : fprintf, stderr;
                md.printError();
                fprintf(stderr, "Unknown error.");
            }


            if(reqInfo.haveRequest && !reqInfo.isProceeded && filterFunc !is null) {
                // もしフィルターを満たさないなら，次の受信信号を受信する
                if(!filterFunc(receiveBuffers))
                    continue Lnextreceive;
            }


            // コピーする
            if(reqInfo.haveRequest && reqInfo.reqBuffers[0].length != 0) {
                reqInfo.isProceeded = true;     // 現在処理中であるフラグを立てる
                immutable numCopy = min(reqInfo.reqBuffers[0].length, receiveBuffers[0].length);
                foreach(i; 0 .. nRXUSRP) {
                    reqInfo.reqBuffers[i][0 .. numCopy] = receiveBuffers[i][0 .. numCopy];
                    reqInfo.reqBuffers[i] = reqInfo.reqBuffers[i][numCopy .. $];
                }
            }

            // レスポンスを返す
            if(reqInfo.haveRequest && reqInfo.reqBuffers[0].length == 0) {
                rxMsgQueue.pushResponse(reqInfo.req, RxResponse!C(RxResponseTypes!C.Receive(cast(C[][]) reqInfo.rxReq.buffer)));
                dbg.writeln("Push Response!");
                reqInfo.initialize();
            }
        }
    }();

    // Shut down receiver
    rx_stream.issue(StreamCommand.stopContinuous);

    if(error)
        throw error.makeException();
}
