#pragma once
#include <mutex>

// A condition-variable predicate must change under the waiter's mutex. Atomic
// predicate fields alone do not prevent a notification between the predicate
// check and the wait's unlock/sleep, which leaves it asleep until its deadline.
template<class Mutex,class Condition,class Publish>
void NativeMacPublishDecoderState(Mutex &mutex,Condition &changed,Publish publish) {
    {std::lock_guard lock(mutex);publish();}
    changed.notify_all();
}
