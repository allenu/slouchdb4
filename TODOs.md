

- [ ] Make remote file sync and diff pulling work
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

