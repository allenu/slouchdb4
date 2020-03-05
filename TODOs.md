
- [x] Refactor so that Session doesn't talk to Database at all. Instead it should delegate out
      the database requests to the client, who can then make those requests on its behalf.
    - [x] Get rid of "Database" class
        - [x] Move its business logic up to "Session"
        - [x] Get rid of ObjectStore from Database/Session

- [ ] Support SQLite ObjectStore
    - [ ] Remove insert() and just use replace() ?

    - [ ] Figure out how to use Sqlite for ObjectHistoryStore

- [ ] BUG: PeopleApp - if you edit a field and then save, then sync, sometimes it doesn't push up the changes
    - Is it b/c pending updates aren't saved? And when you quit and then later re-load, it's not seen as a pending
      update?

- [x] Major redesign to handle external data storage and caching: Instead of implementing any data storage
      or querying semantics, we should abstract all this to a protocol and make use of existing database
      tech like SQLite.
      - Store objects in external database
      - [x] Store object histories somewhere else !?
        - or use the same database to store the list of ObjectDiffs?
        - [x] Can also abstract object diff storage so that 
            - all diffs go in one database (like SQLite)
            - each diff has a foreign key to identify the object it applies to
            - when new diffs come in, insert it into the database (if not there already)
            - when applying new journal diffs in memory, fetch all diffs from the store in
              timestamp order and play them back as necessary
        - [x] Create ObjectHistoryStore
        - [x] Make ObjectHistoryTracker use ObjectHistoryStore
        - [x] ObjectHistoryTracker should have an ObjectHistoryStoring and not histories + pendingUpdates

    - [x] Create or modify ObjectCache abstraction to emphasize that it also does
        - [x] Move Database code that deals with ObjectStore and cache-like business logic into InMemObjectStore
            - [x] sortedIdentifiers
            - [x] FetchCursor nextObjectOffset and predicate

        - [x] fetch()
        - [x] insert/remove/update
        - [x] cursor management (for SQLite this might just be storing an opaque pointer to
              the sqlite cursor). Basic point is that client should get back a "cursor" and
              can use it to fetch more rows from the database. This way we can fetch in
              increments of rows (like 50 at a time) so we don't load everything all at once.

- [x] BUG: Database.fetch(of type:) doesn't actually use type when calling fetchMore()
    - [x] FetchCursor should include type
    - [x] type should be optional (if not included, just fetch all types)

- [-] MAJOR design bug:
    - [-] It's possible that if we process one journal at a time *fully* that we will hit an "update" command in one journal
          before we actually encounter the *insert* command in another one. In such a scenario, we will not store the update
          because the object doesn't exist yet...

          -- See code in ObjectHistoryTracker.swift:244

          - [ ] Write unit test to prove we handle this appropriately

          Solution:
          - if encountered an update or remove on an object that is not yet in the cache, create the entry
            and just mark it as .replay processing state, add to pending updates
          - when going through pending updates, if we encounter a set of diffs where
            it is of type .replay AND the first diff is not .insert
            => just ignore it and keep it in the pending updates

            we may yet pick up the .insert in a future .journal that we process

        => Turns out I do handle this properly. I just have bad journals that end up removing the same item multiple
            times.
            - [-] Figure out how I should handle these ...
                - One option is to just keep the journal around and have a field that says it's "deleted".
                  However, this makes fetching slightly more complicated since I have to filter out those deleted entries.
                - Another option is to store the identifiers of all those items already deleted, so then we can still assert
                  if we try to delete an item that doesn't exist and we legitimately have not yet encountered it :shrug:

- [ ] Update PeopleApp to handle pagination
    - [x] Assume N entries can appear on screen at a time and fetch 2N entries
    - [x] When we display entry 2N * 0.75, start fetching another N entries
    - [x] have a cached window of some M entries - enough below and above current window
    - [ ] if we scroll up beyond the current cached entries, do a *reverse* fetch

- [ ] Add "revese" fetch from a given cursor position
    - will return N entries going backwards from a given position in the index
    - [ ] Add a fetch with query as well
        - make it stop searching when it finds N entries or when it gets to the start of the list
        - make sure to indicate "no more results" if we get to the first entry

- [ ] Store ObjectHistoryTracker histories and ObjectCache objects in sqlite
    - [ ] cache N entries in memory at a time and evict least used if it fills up
        - [ ] Evict M entries in the cache to allow for more room
    - [ ] only write to sqlite when
        - [ ] cache entry is evicted
        - [ ] we are doing a 'save' operation
    - [ ] make sure we save regularly
        - [ ] when app is backgrounded
        - [ ] after N seconds have elapsed since the last save (and there are unsaved entries)
    - [ ] Design the wrapper around Sqlite:
        - [ ] init with url
        - [ ] if db doesn't exist, create it
            - [ ] create the table
        - [ ] add wrapper to insert a new object
        - [ ] add wrapper to remove an existing object


- [-] Figure out how to solve these hard questions
    - [-] If you have a large database and want to do a sort on a non-indexed property, how do you do it??
        - very slow, but low footprint: find N lowest items, then return; then find next N items (making sure
          to only search items greater than the last item in the first query), continue on until you've
          exhausted the list

- [-] See if we can index off a given property instead of just by identifier -- how would it work?

- [x] Try loading the SlouchDB2 journal files
    - [x] Write some Swift code that loads a v2 journal file into mem and writes it out as v4
    - [x] Write an app that searches a directory for .journal files and outputs .journal-v4 files

- [ ] BUG: if you type 'alice' in the people app and then add random entries, eventually one
      will be "Alice" but it won't show up in the search results

- [ ] Figure out background execution policy
    - Should RemoteFileStore take care of issuing code in background?
    - Or should they assume they will already be in a background thread and let JournalManager do that?
      - If so, this gives more freedom to scheduling to JournalManager

    - [x] Should JournalFileManager handle long-running tasks or should we just have JournalManager handle it?
        => don't bother with JournalManager handling it
        - the only "long-running" task is syncFiles()
        - other tasks may be slow, but caller can make request in its own background thread if desired

    - [ ] figure out which requests are synchronous and which are not

        - synchronous
            - fetchLatestDiffsWithoutSync(completion:) can be synchronous
            - save(to:)
            - addtoLocalJournal(diff:)

        - async
            - syncFiles(completion:)
            - fetchLatestDiffs() since it may do a sync

    - [ ] figure out which requests mutate state
        - syncFiles()
            - replaces local copies of remote journal files
            - should only be one syncFiles() call happening at any one time

        - addToLocalJournal(diff:)
            - updates local journal file
            - generally only one call at a time

        - fetchLatestDiffsWithoutSync
            - updates byte offsets for each journal, but only at end of request
            - only one call at a time
            - [ ] Make this synchronous and have client do the mutation part:
                - [ ] fetchlatestDiffsWithoutSync should return just the diffs and the new journal byte offsets
                - [ ] add updateJournalOffsets(byteOffsets: [String : UInt64]) which just mutates the
                    journal offsets and updates to the new values provided. HOWEVER, it should only do it
                    if the new indices are GREATER than the old ones.
                - [ ] Get rid of FetchJournalDiffsResponse since .failure never happens

    - [ ] Should fetches be cancellable (if they take too long)
        - Should they quit after N entries?
        - Maybe have a cursor that lets you re-issue the search starting from a specific index?

    Principles/constraints:
    - Session should hide all background execute from its client.
    - JournalManager itself may have some background execution (like when it needs to do file-copying or
      replacing due to a remote sync)

    Decision:
    - JournalManager should do all background threading it needs and call completions in main thread

    - fetchLatestDiffs(completion:) need not use background threading itself
    - fetchLatestDiffsWithoutSync(completion:) also doesn't need to execute in the background. Caller can call
      it in background if it desires.
    - syncFiles(completion:) -- 
    - save(to:) is synchronous



- [x] BUG: PeopleApp - if you type a search and then sync the database, the search should still apply

- [x] BUG: Sync can never end !?
    - Bug is that when we have a lot of entries to sync and get back "partial" results, if we keep fetching
      again and again while we received partial results, we do not update the byte counter for the journals.
      We only update the byte counter when we finish merging. But this means fetches will continue forever.

      Possible fixes:
      - 1. execute the callback even when partial results are received, even if they have not been merged.
           - However, this isn't a good fix because the whole point of the callback was to ensure that
             the client of JournalManager has committed the diffs it received and "saved" them. If we don't
             do it this way, we could cause the journal byte offsets to be ahead of what the caller has
             processed, thereby losing data if we crash.

      - 1a. partial results should include the last journal byte offsets
           - when doing subsequent fetches, pass back in the state of the last journal byte offsets
           - we can then continue where we left off

           - This should work, but it still doesn't follow the design intent of partial fetches. The
             whole reason partial fetches exist is that the JournalManager doesn't want the caller to
             have too many things to process all at once. The caller really should process the partial
             diffs it gets before coming back for more.

      - 2. always merge even on partial results
       
           - This seems to be the correct solution and is in line with the design tenet of "process
             smaller chunks of a large set of diffs". The whole idea was to reduce how many diffs
             are in memory at a time. In practice, the number of diffs processed at a time may be
             so large anyway (thousands of entries) that in practice we don't normally do partial
             results anyway.

- [ ] Smarter tableView loading
    - [x] Only fetch max number of entries that are visible at a time
    - [x] As user scrolls down, fetch more entries if needed
    - [ ] Allow fetch results to complete asynchronously
        - i.e. show a "loading..." cell if needed

- [ ] Test large databases
    - [x] Modify PeopleApp to search name
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

