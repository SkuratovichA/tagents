//! How the crate takes a lock: a panic on another thread does not make this one panic too. What sits under these locks (a buffer of output, a list of watchers, a map of calls) is valid between any two of its steps, so the data of a poisoned lock is still good.

use std::sync::{Mutex, MutexGuard, PoisonError};

pub(crate) fn locked<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}
