/* Copyright 2016 Software Freedom Conservancy Inc.
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution.
 */

/**
 * Similar to RemoveEmail, except this command ''always'' issues the command to remove all mail,
 * ensuring the entire folder is emptied even if only a portion of it is synchronized locally.
 */

private class Geary.ImapEngine.EmptyFolder : Geary.ImapEngine.SendReplayOperation {
    private MinimalFolder engine;
    private Cancellable? cancellable;
    private Gee.Set<ImapDB.EmailIdentifier>? removed_ids = null;

    public EmptyFolder(MinimalFolder engine, Cancellable? cancellable) {
        base("EmptyFolder", OnError.RETRY);

        this.engine = engine;
        this.cancellable = cancellable;
    }

    public override async ReplayOperation.Status replay_local_async() throws Error {
        // mark everything in the folder as removed
        removed_ids = yield engine.local_folder.mark_removed_async(null, true, cancellable);
        if (removed_ids != null && !removed_ids.is_empty) {
            yield this.engine.update_email_counts(cancellable);
            engine.email_removed(removed_ids);
        }
        return ReplayOperation.Status.CONTINUE;
    }

    public override void get_ids_to_be_remote_removed(Gee.Collection<ImapDB.EmailIdentifier> ids) {
        if (removed_ids != null)
            ids.add_all(removed_ids);
    }

    public override async void replay_remote_async(Imap.FolderSession remote)
        throws GLib.Error {
        // STORE and EXPUNGE using positional addressing: "1:*"
        Imap.MessageSet msg_set = new Imap.MessageSet.range_to_highest(
            new Imap.SequenceNumber(Imap.SequenceNumber.MIN));
        yield remote.remove_email_async(msg_set.to_list(), cancellable);
    }

    public override async void backout_local_async() throws Error {
        if (removed_ids != null && removed_ids.size > 0) {
            yield engine.local_folder.mark_removed_async(removed_ids, false, cancellable);
            yield this.engine.update_email_counts(cancellable);
            engine.email_inserted(removed_ids);
        }
    }

    public override string describe_state() {
        return "removed_ids.size=%d".printf((removed_ids != null) ? removed_ids.size : 0);
    }

}
