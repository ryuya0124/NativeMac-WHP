#include "DecoderWake.h"
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <future>
#include <stdexcept>
#include <thread>

// Expose the publisher's exact lock attempt to force the check/wait race,
// rather than relying on scheduler luck or a repeated sleep-based stress test.
struct ObservedMutex {
    std::mutex mutex;
    std::atomic<bool> observe{false};
    std::promise<void> attempted;
    void lock(){if(observe.exchange(false))attempted.set_value();mutex.lock();}
    void unlock(){mutex.unlock();}
};

int main(){
    using namespace std::chrono_literals;
    for(unsigned transition=0;transition<3;transition++) {
        ObservedMutex mutex;std::condition_variable_any changed;
        bool ready=false;auto attempted=mutex.attempted.get_future();
        std::unique_lock lock(mutex);
        // We have just checked a false predicate and still hold its mutex.
        if(ready)throw std::runtime_error("unexpected initial predicate");
        mutex.observe=true;
        std::thread publisher([&]{NativeMacPublishDecoderState(mutex,changed,[&]{ready=true;});});
        if(attempted.wait_for(2s)!=std::future_status::ready)std::terminate();
        // Publication cannot occur in the vulnerable interval before wait.
        if(ready)std::terminate();
        bool woke=changed.wait_for(lock,2s,[&]{return ready;});
        lock.unlock();publisher.join();
        if(!woke)throw std::runtime_error("lost decoder state notification");
    }
    puts("decoder barrier/end/cancel publication cannot race the predicate-to-wait gap");
}
