module rx.scheduler;

import rx.disposable;
import rx.observer;
import rx.observable;

import core.thread : Thread;
import std.range : put;
import std.parallelism : TaskPool, taskPool, task;

interface Scheduler
{
    void start(void delegate() op);
}

class LocalScheduler : Scheduler
{
public:
    void start(void delegate() op)
    {
        op();
    }
}
class ThreadScheduler : Scheduler
{
    void start(void delegate() op)
    {
        auto t = new Thread(op);
        t.start();
    }
}
class TaskPoolScheduler : Scheduler
{
public:
    this(TaskPool pool = taskPool)
    {
        _pool = pool;
    }

public:
    void start(void delegate() op)
    {
        _pool.put(task(op));
    }

private:
    TaskPool _pool;
}

struct ObserveOnObserver(TObserver, TScheduler, E)
{
public:
    static if (hasFailure!TObserver)
    {
        this(TObserver observer, TScheduler scheduler, Disposable disposable)
        {
            _observer = observer;
            _scheduler = scheduler;
            _disposable = disposable;
        }
    }
    else
    {
        this(TObserver observer, TScheduler scheduler)
        {
            _observer = observer;
            _scheduler = scheduler;
        }
    }
public:
    void put(E obj)
    {
        _scheduler.start({
            static if (hasFailure!TObserver)
            {
                try
                {
                    _observer.put(obj);
                }
                catch (Exception e)
                {
                    _observer.failure(e);
                    _disposable.dispose();
                }
            }
            else
            {
                _observer.put(obj);
            }
        });
    }
    static if (hasCompleted!TObserver)
    {
        void completed()
        {
            _scheduler.start({
                _observer.completed();
            });
        }
    }
    static if (hasFailure!TObserver)
    {
        void failure(Exception e)
        {
            _scheduler.start({
                _observer.failure(e);
            });
        }
    }
private:
    TObserver _observer;
    TScheduler _scheduler;
    static if (hasFailure!TObserver)
    {
        Disposable _disposable;
    }
}

struct ObserveOnObservable(TObservable, TScheduler)
{
    alias ElementType = TObservable.ElementType;
public:
    this(TObservable observable, TScheduler scheduler)
    {
        _observable = observable;
        _scheduler = scheduler;
    }
public:
    auto subscribe(TObserver)(TObserver observer)
    {
        alias ObserverType = ObserveOnObserver!(TObserver, TScheduler, TObservable.ElementType);
        static if (hasFailure!TObserver)
        {
            auto disposable = new SingleAssignmentDisposable;
            disposable.setDisposable(disposableObject(doSubscribe(_observable, ObserverType(observer, _scheduler, disposable))));
            return disposable;
        }
        else
        {
            return doSubscribe(_observable, ObserverType(observer, _scheduler));
        }
    }
private:
    TObservable _observable;
    TScheduler _scheduler;
}

ObserveOnObservable!(TObservable, TScheduler) observeOn(TObservable, TScheduler : Scheduler)(auto ref TObservable observable, TScheduler scheduler)
{
    return typeof(return)(observable, scheduler);
}

unittest
{
    import std.concurrency;
    import rx.subject;
    auto subject = new SubjectObject!int;
    auto scheduler = new LocalScheduler;
    auto scheduled = subject.observeOn(scheduler);

    import std.array : appender;
    auto buf = appender!(int[]);
    auto observer = observerObject!int(buf);

    auto d1 = scheduled.subscribe(buf);
    auto d2 = scheduled.subscribe(observer);

    subject.put(0);
    assert(buf.data.length == 2);

    subject.put(1);
    assert(buf.data.length == 4);
}
unittest
{
    import std.concurrency;
    import rx.subject;
    auto subject = new SubjectObject!int;
    auto scheduler = new LocalScheduler;
    auto scheduled = subject.observeOn(scheduler);

    struct ObserverA
    {
        void put(int n) { }
    }
    struct ObserverB
    {
        void put(int n) { }
        void completed() { }
    }
    struct ObserverC
    {
        void put(int n) { }
        void failure(Exception e) { }
    }
    struct ObserverD
    {
        void put(int n) { }
        void completed() { }
        void failure(Exception e) { }
    }

    scheduled.doSubscribe(ObserverA());
    scheduled.doSubscribe(ObserverB());
    scheduled.doSubscribe(ObserverC());
    scheduled.doSubscribe(ObserverD());

    subject.put(1);
    subject.completed();
}
unittest
{
    import core.atomic;
    import core.sync.condition;
    import std.meta;
    import rx.util : EventSignal;
    enum N = 4;

    foreach (T; AliasSeq!(LocalScheduler, ThreadScheduler, TaskPoolScheduler))
    {
        auto scheduler = new T;
        auto signal = new EventSignal;
        shared count = 0;
        foreach (n; 0 .. N)
        {
            scheduler.start((){
                atomicOp!"+="(count, 1);
                Thread.sleep(dur!"msecs"(50));
                if (atomicLoad(count) == N) signal.setSignal();
            });
        }
        signal.wait();
        assert(count == N);
    }
}
