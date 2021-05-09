
--------------------------------------------------------------------------------
# HOW TO USE

    // 
    // 1. Setup
    //

    let journalManager = YourJournalManager()
    let objectHistoryStore = YourObjectHistoryStore()

    let changeTracker = ChangeTracker(journalManager: journalManager, objectHistoryStore: objectHistoryStore)

    // Change tracker delegates execution of commands
    changeTracker.delegate = self


    //
    // 2. Data mutation
    //
    // Whenever there is a data mutation, package it in a command and execute this
    //

    changeTracker.append(command) { 
        // completion called when command is finished executing and has modified your data store
    }


    //
    // 3. Sync
    //
    // A sync operation ensures that the local journals and remote journals are up to date with each other.
    //
    // A sync operation is made up of these steps:
    // - pull down any remote journals that have changed
    // - push up any *local* journals that have changed
    // - this will call JournalManager to fetch the latest commands
    // - if any new commands were found in the remote journals, add them to the pending changes via changeTracker.append()

    changeTracker.sync { response in
        // Completion block is called once all remote changes have been applied locally.
        // response is .success or .failure
    }


    // 
    // Handling commands
    // 

    // Your ChangeTrackerDelegate should handle any requests by ChangeTracker to actually execute commands on the
    // data store:

    func changeTracker(_ changeTracker: ChangeTracker, requestsExecute commands: [Command], for identifier: String, 
        startingAt playbackPosition: PlaybackPosition, completion: @escaping (Bool) -> Void) {  
        // execute commands
        // when done, call completion(true)
    }


That's the long and short of it. It's up to your ChangeTrackerDelegate to actually implement the command execution.
Once you're done making the changes to the local database, call completion() to let ChangeTracker know it can continue
onto the next set of queued commands.


--------------------------------------------------------------------------------
# Managing UI and database sync

Another type of "sync" we should mention is keeping your UI and your data in sync. If you make use of a Table Views,
you will need to ensure that if you make any modifications to the underlying data, you make the appropriate changes
to the Table View.

Generally, in your ChangeTrackerDelegate, once you are done "playing back" the commands given, you should do a commit
on your database and then immediately update your UI to match it. Only once your UI has updated should you call the 
completion passed in the delegaet method. This will ensure that the ChangeTracker does not continue making requests
to update the database via delegate callbacks.

--------------------------------------------------------------------------------
# How does ChangeTracker manage mutation requests?

If ChangeTracker has multiple clients appending commands at different times, including itself during a sync operation,
how do we ensure data integrity? ChangeTracker makes use of a single synchronous DispatchQueue to handle the following:

    - enqueueing commands
    - processing commands
    - kicking off a sync

During a sync, we do NOT block off requests to enqueue additional commands. 

There can only be one processing request at a time. That is, while existing commands are being executed, no further
requests to execute more commands are allowed. Instead, they get tacked onto the queue of commands are only executed
once the current processor is done.

