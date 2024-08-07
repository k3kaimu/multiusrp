module dispatcher;

import std.stdio;
import controller;
import device;
import utils;


class MessageDispatcher
{
    alias dbg = debugMsg!"MessageDispatcher";

    this(IDevice[string] devices, IController[string] controllers)
    {
        this.devs = devices;
        this.ctrls = controllers;
    }


    void dispatchAtServer(scope const(char)[] target, scope const(ubyte)[] msgbuf, scope void delegate(scope const(ubyte)[]) writer)
    {
        if(msgbuf.length == 0) return;
        switch(msgbuf[0]) {
        case 0b00001000:    // すべてのコントローラーを動かす
            foreach(t, c; ctrls)
                c.resumeDeviceThreads();
            break;
        case 0b00001001:    // すべてのコントローラーを止める
            foreach(t, c; ctrls)
                c.pauseDeviceThreads();
            break;
        default:
            dbg.writefln("msgtype = %s is not supported.", msgbuf[0]);
            break;
        }
    }


    void dispatchAtAllCtrls(scope const(char)[] tag, scope const(ubyte)[] msgbuf, scope void delegate(scope const(ubyte)[]) writer)
    {
        foreach(t, c; ctrls)
            c.processMessage(msgbuf, writer);
    }


    void dispatchAtAllDevs(scope const(char)[] tag, scope const(ubyte)[] msgbuf, scope void delegate(scope const(ubyte)[]) writer)
    {
        writefln("[WARNIGN] tag '@alldevs' has not implemented yet.", tag);
    }


    void dispatchOtherRegex(scope const(char)[] tag, scope const(ubyte)[] msgbuf, scope void delegate(scope const(ubyte)[]) writer)
    {
        if(auto c = tag in ctrls)
            c.processMessage(msgbuf, writer);
        else if(auto d = tag in devs)
        {
            if(msgbuf.length == 0) return;
            switch(msgbuf[0]) {
            case 0b00000010:    // SetParam
                writefln("[WARNIGN] SetParam does not implemented yet.");
                break;
            case 0b00000011:    // GetParam
                writefln("[WARNIGN] GetParam does not implemented yet.");
                break;
            default:
                dbg.writefln("msgtype = %s is not supported.", msgbuf[0]);
                break;
            }
        }
        else
            writefln("[WARNIGN] cannot find tag '%s'", tag);
    }


    void dispatch(scope const(char)[] target, scope const(ubyte)[] msgbuf, scope void delegate(scope const(ubyte)[]) writer)
    {
        if(target == "@allctrls") {
            this.dispatchAtAllCtrls(target, msgbuf, writer);
        } else if(target == "@server") {
            this.dispatchAtServer(target, msgbuf, writer);
        } else {
            this.dispatchOtherRegex(target, msgbuf, writer);
        }
    }


  private:
    IDevice[string] devs;
    IController[string] ctrls;
}