
- [ ] Design folder structure for everything

    journals/
        remotes/
        locals/
        manager/
            JSON data for stored state of journal manager
            - journal byte offsets
            - local identifier (s)
            - remote file versions

    object-history-db/
        sqlite stuff or JSON data

    object-cache-db/
        sqlite stuff or JSON data

- [ ] Test JournalManager
    - [x] Break out the sync logic so that it's functional

        - input
            - local identifier
            - local versions dictionary
            - remote versions dictionary

        - output
            - list of files to push
            - list of files to pull

    - [ ] Design the data used for each test

        - [x] SYNCING TESTS
            - need to set local versions dictionary
            - need to set remote versions dictionary

        - [ ] FETCHING TESTS
            - simulate each journal's total diff count
            - each journal will return an .insert diff with identifier of "N" where N is the journal index 
              - it's true that the diffs are repeated .inserts that would never happen in real life, but we're not testing that
              - timestamp will be a 1 second offset from some reference point so that we can test that it's the diff index we want
            - when each journal "read" is called, we just compute how many diffs to return, the starting index (for the timestamp
              creation) and then we create that many diffs


    - [ ] Make a list of tests that JournalManager should undergo

        SYNCING tests

        - we have no local files and no remote files and we do a sync
            => no data transfer should occur

        - we have one local journal and no remotes and we do a sync
            => local journal should be pushed up

        - we have one local journal and remote knows about its same version
            => local journal should NOT be pushed up

        - we have one local journal and remote knows about an older version
            => local journal should be pushed up

        - we have one remote file and not locally
            => we should pull it down
            => the local known version should be updated

        - we have one remote file and not locally and we call sync twice
            => we should pull it down just the first time
            => the second time should be a no-op

        - we have one remote file and have it locally at same version
            => we should NOT pull it down

        - we have one remote file and have it locally at different version
            => we should pull it down

        - we have two remote files, one we have locally at same version and one we don't know about
            => we should only pull down one we don't know about

        - we have two remotes that we don't have locally
            => we should pull both down

        - we have local file and remote doesn't exist, we have two remotes that we don't have locally
            => we push push local up
            => we should pull both remotes down

        - we have remote files and they no longer exist remotely ...
            => we should leave alone the local copy of the remote files ??
            => we should NOT push up the local copy of the remotes

        SYNCING ERROR scenarios

        - we get remote versions of files, but it errors out
            => we should error the sync immediately

        - we get remote versions okay, but pushing local file errors
            => we should error out after pushing
            => we should NOT update local version dictionary

        - we get remote versions okay, we push local okay, but pulling remotes causes one to error (1st of 3)
            => we should have one error
            => other remotes should be updated still

        - we get remote versions okay, we push local okay, but pulling remotes causes one to error (2nd of 3)
            => we should have one error
            => other remotes should be updated still

        - we get remote versions okay, we push local okay, but pulling remotes causes one to error (3rd of 3)
            => we should have one error
            => other remotes should be updated still

        FETCH LATEST DIFFS TESTS
        note: the diff contents for these tests don't actually matter because we don't even process them
        here. We just care that we return the number of diffs that are available from a journal.

        - test that we never try to get from the local journal. create a local journal and fill it with diffs,
          then call fetch latest
          => should return no results

        - have one remote journal with no entries
          => should return no results

        - have one remote journal with 1 entry
          => should return 1 diff

          call it again
          => should return 0 diffs

        - have one remote journal with maxDiffs - 1 entry
          => should return maxDiffs - 1

          call it again
          => should return 0 diffs

        - have one remote journal with maxDiffs
          => should return maxDiffs

          call it again
          => should return 0 diffs

          => should return 1 diff

        - have one remote journal with maxDiffs + 1 entry
          => should return maxDiffs

          call it again
          => should return 1 diff (the last one)

          call it again
          => should return 0 diffs

        - have two journals with 1 diff in each
          => should return 1 diff from each journal

        - have two journals with first having 1 entry, second with 5
          => should return 6 diffs

        - have two journals, first with maxDiffs + 1, second with 1
          => should return maxDiffs

          call again
          => should return 2 diffs (one from each journal)


        - have three journals, each with maxDiffs + 1
          => should return maxDiffs

          call again
          => should return maxDiffs

          call again
          => should return maxDiffs

          call again
          => should return 3 diffs

          call again
          => should return 0 diffs

        - test that if we do NOT call CallbackWhenDiffsMerged() method, the journal byte offsets do NOT update

        - test that if we DO call CallbackWhenDiffsMerged the byte offsets update
            - test with one journal
            - test with two journals

    - [x] Break out code that actually does the operations so it takes the output of the above and processes
          each stage separately

          - note: it will still need to do the fetch diffs operation at the end

    - [ ] Implement saving
        - [ ] ObjectCache saving
            - [ ] InMemObjectCache
                - [ ] save to a URL path a json file
                - [ ] restore from a URL path

            - [ ] SqliteObjectCache
                - [ ] initialize with path to sqlite database
                    - create it if necessary
                        - each entry will just be
                            - identifier (hopefully we can use our own UUID)
                            - type column
                            - timestamp
                            - properties JSON payload
                - [ ] save ? 

        - [ ] ObjectHistoryTracker
            - [ ] InMem version
                - [ ] save histories to json file
                - [ ] save list of pending updates to json file
            - [ ] SQlite version
                - [ ] initialize database
                    - each entry is just
                        - processing state
                        - next diff index to process (only if non-replay style, otherwise will be 0)
                        - diffs as a JSON array
                - [ ] generate pending from scratch when loading file ?? might be inefficient to go
                      through every object EVER
                      - [ ] Could store last time we processed updates and find all histories that were updated since then
                    - if a history for an object has a processing state that has nextDiff > total diffs OR is .replay,
                      add it to the list of pendingUpdates

    - [x] JournalManager journals[] dictionary should be [String : UInt64] where each value
          is a byte offset into the file stream, nothing more. We should not store "cursor"
          information anymore. Just use a byte offset.

          Nothing needs to use the nextDiffIndex!

    - [x] JournalManager should not know about journal readers even...
        - Just write a JournalFileManager.readNextDiffs(for identifier: String, at byteOffset: UInt64) -> Result
          - and from the Result, you can get
            - diffs
            - next byte offset
            - (maybe EOF data)

    - [ ] Implement the *real* JournalFileManager
        - [ ] Should "own" journal readers which it routes to via readNextDiffs()
        - [ ] Implementation details:
            - local journals in local/
            - remote journals for syncing in remote/

    - [x] JournalManager should not know about journal WRITERS either...
        - just write a JournalFileManager.append(diff: ObjectDiff, to identifier: String)

    - [x] Update JournalManagerStoredState so that it doesn't have JournalReaderState, but String : UInt64 too


- [ ] Make remote file sync and diff pulling work
    - [ ] Test file sync - syncFiles(completion:)
    - [ ] Test grabbing latest diffs from journals - fetchLatestDiffsWithoutSync

    - [ ] Before pushing local file, be sure latest edits are saved to disk

    - [ ] Remote file sync
        - [x] Push local journal only if remote is old
        - [ ] Fail early if local push fails
        - [ ] Fetch all remotes that
            - are newer than what we have
            - don't exist locally

    - [ ] See if our fetchLatestDiffsWithoutSync can compute the percent of diffs processed out of all pending somehow... ???
        - maybe it can be based on the number of journals we know have changed ??

    - [ ] fetchLatestDiffs
        - [ ] It should be possible to do file syncing optionally
            - if remote hasn't been set up yet
            - if we know we're not on the internet
            - if we know there are pending local changes and we don't want to
              slow things down by first syncing remote files

              - [ ] Move remote file sync to its own method with a completion callback
                - On success (or failure), we execute the "get latest diffs"

        - [ ] Write get latest diffs algorithm:

            - while num diffs collected < MaxDiffsPerTransaction
                - fetch N diffs from next journal that has some
                - add new cursor position to "potential cursor updates"

            - if we hit max diffs per transaction, set a flag that "there may be more results" and pass it back to
              the completion for fetchLatestDiffs

            - if we collected > 0 diffs,
                - call completion for processing diffs
                - provide it with a callback to let us know when it's done applying the changes (and saving them)
                - once it calls our callback,
                    - update the cursor positions for the journals we played back
                    - save those cursor positions

- [ ] Add support for rotating local identifiers
    - Requirements:
        - if local file gets too big, update local identifier
        - must still be able to push local journals even if they are not the current one

