# ShareDB Operations Sync Module Overview

## Responsibilities:

* Open and disconnect sharedb socket depending on user status
* Register a document with collaboration and operation syncing cloud services
* Send and receive operations
  * Track user changes and send operations taking into consideration various network issues
  * Apply operations to document taking into consideration various network issues
* Sending and receive cursor positions
  * Unlike operations, cursor position are non persistent data. Since Memrey is designed to scale horizontally, all non-persistent data is synced using Redis. This way I can keep adding servers and load balance between them as needed.

## Things I would change:

The biggest issue with the Memrey codebase is use of a global variable system. I have moved away from this overtime and I know how I would redo this system but since Memrey is not my focus anymore things like this is sidelined for the future.

## Use of Tracker.autorun:

* I make frequent use of autorun functions - docs: https://docs.meteor.com/api/tracker.html
* It is amazing for dependency tracking to rerun certain computations when needed. This is a big part of making the UI reactive and always up to date with the latest data. It is really a great way to write simple understandable code that is reactive. The use of tracker with ReactiveVars (https://docs.meteor.com/api/reactive-var.html) allows you to do  functional programming in a clear understandable way.
