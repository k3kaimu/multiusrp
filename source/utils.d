module utils;

import core.thread;
import std.stdio;

template debugMsg(string tag)
{
    enum string _tag_ = "[" ~ tag ~ "] ";

    void writef(T...)(string fmt, T args)
    {
        debug std.stdio.writef(_tag_ ~ fmt, args);
    }

    void writef(string fmt, T...)(T args)
    {
        debug std.stdio.writef!(_tag_ ~ fmt)(args);
    }

    void writefln(T...)(string fmt, T args)
    {
        debug std.stdio.writefln(_tag_ ~ fmt, args);
    }

    void writefln(string fmt, T...)(T args)
    {
        debug std.stdio.writefln!(_tag_ ~ fmt)(args);
    }

    void write(T...)(T args)
    {
        debug std.stdio.write(_tag_, args);
    }

    void writeln(T...)(T args)
    {
        debug std.stdio.writeln(_tag_, args);
    }
}


bool notifyAndWait(shared(bool)[] flags, size_t myIndex, Fiber ctxSwitch, ref shared(bool) killswitch)
{
    import core.atomic;

    atomicStore(flags[myIndex], true);

    // 他のスレッドがすべて準備完了するまでwhileで待つ
    while(!atomicLoad(killswitch)) {
        bool check = true;
        foreach(ref b; flags)
            check = check && atomicLoad(b);

        if(check)
            return true;

        if(ctxSwitch !is null)
            ctxSwitch.yield();
    }

    return false;
}


bool waitDone(ref shared(bool) flag, Fiber ctxSwitch, ref shared(bool) killswitch)
{
    import core.atomic;

    while(!atomicLoad(killswitch)) {
        if(atomicLoad(flag))
            return true;

        if(ctxSwitch !is null)
            ctxSwitch.yield();
    }

    return false;
}
