
- [ ] Test large databases
    - [ ] Modify PeopleApp to search name
        - add search field
        - as you type, redoes search query
    - [ ] Create test journal that has 10,000 entries
        - paginated list of entries
        - search by name fragment as you type
        - search is paginated
        - test searching for a string that does not match anything in the database, then
          changing the query to something that does
          - should maybe cancel the original search if it's still ongoing

    - [ ] Create test journal that has 100,000 entries
    - [ ] Create test journal that has 1,000,000 entries

- [ ] Create utility app that can load any arbitrary database
    - has search field where you can type fieldname:value ??
    - has a list of N entries (paged and loaded in memory on the fly)

- [ ] Figure out background execution policy
    - Should RemoteFileStore take care of issuing code in background?
    - Or should they assume they will already be in a background thread and let JournalManager do that?
      - If so, this gives more freedom to scheduling to JournalManager

    - [ ] Should JournalFileManager handle long-running tasks or should we just have JournalManager handle it?

    - [ ] Should fetches be cancellable (if they take too long)
        - Should they quit after N entries?
        - Maybe have a cursor that lets you re-issue the search starting from a specific index?

- [-] Make RemoteFileStoring.push(localFile: URL) be push(identifier:) instead
    => Can't really do this since RemoteFileStoring doesn't keep track of file locations (especially now
       that we have working folder and storage folder)

- [ ] Test: RemoteFileStore.fetchFiles() returns an incomplete set of files and versions
    - Should still work
    - Files missing are just not updated

- [ ] Error-recovery
    - [ ] BUG: Couldn't parse some of hte journal data. Seems like we were at the wrong offset in the file ?
        -> Yes, we likely had a bad journal file earlier that was out of date due to a bug. When we replaced
           it, the byte index was then wrong.

           We should make it so if a journal disappears, we should remove it from our object state history.
           This way we can easily recover by deleting the journal file.

    - [ ] TEST resiliency of file reader:
        - if we encounter data before a newline that is just garbage, make sure we skip it and recover enough
          to read the next proper line of data

- [x] Feature: Implement Working Folder and Storage Folder
    - [x] JournalFileManager should have optional storageFolderUrl:
    - [x] FileSystemStore shouldn't even have a rootFolderUrl as it's not even used!
    - [x] Test save-as, which should save to new folder
    - [x] Re-enable autosave in all situations

    - [x] BUG: If you add local diffs, save, then close
          Then re-open and add more local diffs, the local diffs overwrite the old ones entirely.
          What we need to do when opening an existing file is COPY the local journals to the working storage FIRST.

    - [x] BUG: Open an existing file, delete some entries, sync, open another existing file and sync. you won't
          pick up the changes. :(
    - [x] BUG: ByteOffsets are going totally wrong... asserts hit all the time now :(
    - [x] BUG: I still noticed that sometimes my journal changes didn't get pushed up to the remote
    - [x] BUG: we can still get into a scenario where we are referencing a temporary folder used by NSDocument to
          save atomically to.

          The fix is to just not save the storageFolderUrl in JournalFileManager.save(to:).
          Only rely on the storageFolderUrl if it is provided on creation. Otherwise, it could
          be anything.
    - [x] BUG: Still have crashes where we try to open a journal in the working folder but it doesn't exist there yet !
          -> is it because the file copy operation doesn't finish in time and we have a race condition?

          - [ ] One graceful way to fix it is if journal file is missing, "forget" about it. Remove it from
                our indexes. Hopefully next time we sync, we try to pull it down correctly.

- [x] BUG: Create two files and make edits and sync back and forth between them
    - eventually if you make edits in one file, it will push (you can check the destination folder to verify)
    - however, if you sync the other file, it will pull (I think) but it does not merge and update :(

    -> Fixed. Due to our JournalFileManager not re-opening the local journal file after a pull.

- [x] BUG: I noticed a previously-saved file would not sync even though new journals were available.
    => Likely due to the saving shenanigans. When file is saved at the moment, all bets are off...

- [x] Update Document model for PeopleApp demo
    - when making local edits, journal diff updates should go to temporary file target
    - when saving, copy the new edits from the temporary file on top of the existing journal,
      then empty out the temporary file target so we are appending from a zero byte file
    - on next save, do the same thing

    - when pulling files from remotes, also save to temporary file folder
    - when saving, copy those files to the save location

    - bottom line:
      - never edit files directly in the save URL unless you are in the middle of a write(to:) request

    - [x] When Document created, immediately create a temp folder
        - copy all locals to it
        - copy all remotes to it

- [x] MAJOR BUG in PeopleApp:
    - [x] Due to autosaving, the location of the file URL changes... not great for our test app which is based on a folder idea
    - [x] Rewrite it as a non-Document-based app. Just a window-based app where you specify the URL and it works off that
          - 
- [x] Bug: if you re-open an existing .People file and hit 'sync', it won't be able to copy over the
      journal to the destination if it's already there.
      - [x] Need to handle overwriting an existing file
      - [x] Make sure file is overwritten for push and pull

- [x] Bug: 
    - create new file
    - select sync folder and tap Sync
    - modify an entry
    - tap Sync again
    - find the journal file and see the diff you just created by modifying
    - modify another entry
    - tap Sync again
    - YOUR EDIT DOES NOT SHOW UP

    - [x] Part of it is due to a "push" not overwriting files
    - [x] Also due to "lastLocalVersionPushed" not being a good mechanism
        - if there any local changes, "lastLocalVersionPushed" doesn't change, so as far as we're concerned,
          we don't need to push
        - [x] We should have a "isDirty" flag to indicate that our local journal has been updated since the
              last push and that we should push to update the remote
        - [x] We should store the isDirty in the stored state

- [x] Major design bug: when you call fetch() -> FetchResult, you get back a list of objects, but not their
      identifiers!!

      We should return [(String, DatabaseObject)]

- [x] Implement file-based Remote Store

- [x] Manage two types of scenarios for Document:
    - [x] New file which has not yet been saved
        - [x] Open temp file and write stream to it
        - [x] When file is saved, close file and copy to permanent location
        - [x] Open new file as stream
    - [x] Opening existing file
        - [x] Open remote file as a stream

- [x] Implement PeopleApp again
    - [x] Build for iOS 12 or 11 (may require changes to FileHandle close() and seek() methods)
    - [x] Build for macOS 10.14 and earlier (close() and seek() issues here too)
    - [x] Podify project
    - [-] Handle delete key on an entry

- [x] Bleh, use expectation() and waitForExpectations() instead of holding onto journalManager as a test instance var

- [ ] Move object-cache.json info to InMemObjectCache
- [ ] Move object-tracker.json info to ObjectHistoryTracker

    - [ ] Consider breaking subclassing Session to handle file-saving stuff:
        - FilebasedSession

- [x] Design folder structure for everything

    remotes/
    locals/
    journal-state.json
        JSON data for stored state of journal manager
        - journal byte offsets
        - local identifier (s)
        - remote file versions

    object-history-db/
        sqlite stuff or JSON data

    object-cache-db/
        sqlite stuff or JSON data

    - to save,

        - objectCache.save(to: url)
        - objectTracker.save(to: url)
        - journalManager.save(to: url)

- [ ] More cleanup
    - [ ] Rename ObjectCache to ObjectStore (also: InMemObjectStore)
    - [ ] Move sortedIdentifiers (really, an index of all objects) into its own "cache"
        - Maybe we can cache/store the index of all object identifiers to disk to reduce
          the need for loading all of them into memory one day
        - We can having a running count of all objects as well (including those that are
          marked as deleted) -- could also separate them out into deleted and not deleted lists

- [ ] Test JournalManager
    - [x] Break out the sync logic so that it's functional

        - input
            - local identifier
            - local versions dictionary
            - remote versions dictionary

        - output
            - list of files to push
            - list of files to pull

    - [ ] Design fetching multiple files at once and only completing once all are pulled down.

    - [ ] Design the data used for each test

        - [x] Fix unit tests:
            - They are creating local instances of objects which are needed for testing...
            - however their completion blocks never execute because the local instances go out of scope before test can finish

        - [x] SYNCING TESTS
            - need to set local versions dictionary
            - need to set remote versions dictionary

        - [x] FETCHING TESTS
            - simulate each journal's total diff count
            - each journal will return an .insert diff with identifier of "N" where N is the journal index 
              - it's true that the diffs are repeated .inserts that would never happen in real life, but we're not testing that
              - timestamp will be a 1 second offset from some reference point so that we can test that it's the diff index we want
            - when each journal "read" is called, we just compute how many diffs to return, the starting index (for the timestamp
              creation) and then we create that many diffs

            - In fact we just need to mock out the number of diffs to return on each request. We don't even really
              need to simulate the byteOffset, but it does help with the implementation...

    - [ ] Make a list of tests that JournalManager should undergo

        SYNCING tests

        x we have no local files and no remote files and we do a sync
            => no data transfer should occur

        - we have one local journal and no remotes and we do a sync
            => local journal should be pushed up

        - we have one local journal and remote knows about its same version
            => local journal should NOT be pushed up

        - we have one local journal and remote knows about an older version
            => local journal should be pushed up

        x we have one remote file and not locally
            => we should pull it down
            => the local known version should be updated

        x we have one remote file and not locally and we call sync twice
            => we should pull it down just the first time
            => the second time should be a no-op

            *** no need: we can just test that if local file is same as remote that nothing happens

        x we have one remote file and have it locally at same version
            => we should NOT pull it down

        x we have one remote file and have it locally at different version
            => we should pull it down

        x we have two remote files, one we have locally at same version and one we don't know about
            => we should only pull down one we don't know about

        x we have two remotes that we don't have locally
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
                - [x] save to a URL path a json file
                    - [x] Implement .save(to:)
                - [x] restore from a URL path
                    - [x] Implement .create(from:)
                        - [x] Could also just pass params in to init() that were loaded from disk externally
                    - [x] return nil on error

        - [ ] ObjectHistoryTracker
            - [x] InMem version
                - [x] save histories to json file
                    - [x] save to a URL path a json file
                        - [x] Implement .save(to:)
                    - [x] restore from a URL path
                        - [x] Implement .create(from:)
                            - [x] Could also just pass params in to init() that were loaded from disk externally
                        - [x] return nil on error

        - [x] Save to journal
            - [x] Test that writing to journal works
        - [x] Load journal
            - [x] Test that reading a journal works
            - [x] Test reading all journal diffs works and eventually stops returning diffs

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

    - [x] Implement the *real* JournalFileManager
        - [x] Should "own" journal readers which it routes to via readNextDiffs()
        - [x] Implementation details:
            - local journals in local/
            - remote journals for syncing in remote/

    - [x] JournalManager should not know about journal WRITERS either...
        - just write a JournalFileManager.append(diff: ObjectDiff, to identifier: String)

    - [x] Update JournalManagerStoredState so that it doesn't have JournalReaderState, but String : UInt64 too

- [x] Make remote file sync and diff pulling work
    - [x] Test file sync - syncFiles(completion:)
    - [x] Test grabbing latest diffs from journals - fetchLatestDiffsWithoutSync

    - [x] Before pushing local file, be sure latest edits are saved to disk

    - [ ] Remote file sync
        - [x] Push local journal only if remote is old
        - [ ] Fail early if local push fails
        - [x] Fetch all remotes that
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

        - [x] Write get latest diffs algorithm:

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

