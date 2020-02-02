# DESIGN

This document lays out some design decisions in SlouchDB4.

# Working Folder vs Storage Folder

## The problem: dealing with NSDocument write operations

SlouchDB4 can make use of two folders when dealing with its persistent data: a working folder and a storage folder.

When creating the PeopleApp test app, I realized that there are some scenarios where you may want to represent
your data as an NSDocument. This can pose a problem, however. SlouchDB4 uses a folder of files to represent the
history of a database (via journals) as well as its current state. 

When a sync occurs, remote journals are downloaded and stored in this database. Additionally, when local changes
are made, the local journal in this folder is updated by appending new entries to it. To reduce the memory 
footprint, appends to this local journal file happen as the edits are made to the database. This means the files
in the NSDocument bundle will be mutated as the document is edited, either from a sync operation or from local
edits.

However, the way NSDocument works, it works exclusively via atomic writes to the document. It's not meant to be
used as a mutating store of data. That is, when any one of NSDocument's write methods is called, the assumption
is that this is the only time the document bundle is modified. If you don't follow this rule, you will be in
for a surprise because the contents of this folder aren't necessarily persisted long-term. When an autosave
occurs, for instance, the target of this write operation is a temporary folder, which may eventually be deleted,
without your app even knowing it. (This has been my experience, at least.)

## The solution: a temporary folder to work in

Because we can't control the contents of the NSDocument write folder, we create a temporary folder to do our
file mutations in. The contents of this folder will be those files that we have modified during the runtime
session. When an NSDocument.write occurs, we will take the contents of the files that were modified here and
ensure they get written to the NSDocument.write folder. 

We could turn this temporary folder into a mirror of the full contents of the NSDocument folder. However, that
would be inefficient since we'd have to copy all the contents of the NSDocument folder whenever we open up an
existing document. To avoid copying files over, the temporary folder will be treated as an "add-on" to the
persistent folder. This is where the concept of "working folder" and "storage folder" come in.

The temporary folder becomes the working folder where edited journals and pulled remote journals can go. The
storage folder is where the unmodified original document files can go. The storage folder can be optional,
in which case the working folder becomes both the temporary folder where edits are made and the folder where
data is stored permanently long-term. (This is the typical non-NSDocument scenario.)

Luckily, only one class needs to make use of the working folder and storage folder: JournalFileManager.

JournalFileManager needs to know about the two folders because when writing new diffs to local journal,
the working folder should always be used. When reading from remote journals, the working folder should be
checked first for the latest version of the journal, but if it is not there, the storage folder should be
checked next.

Note that when a file sync occurs, the RemoteFileStoring implementation doesn't deal with the working
folder or storage folder directly. The JournalManager takes the URL of the file that was downloaded from
the RemoteFileStoring object and immediately passes it to the JournalFileManaging object. The push/pull
operations don't need to know the location of files, at least not until the request to push or pull
actually happens.

## Document write operation

When a document is saved, the other non-journal file Session data can just be written to the long-term
storage folder. As for the journal files, if any locals or remotes are found in the working folder,
they should take precedence over the previous storage folder-based journal files when copying them
over.

