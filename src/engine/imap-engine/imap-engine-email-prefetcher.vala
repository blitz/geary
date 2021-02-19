/*
 * Copyright 2016 Software Freedom Conservancy Inc.
 * Copyright 2019 Michael Gratton <mike@vee.net>
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */

/**
 * Ensures all email in a folder's vector has been downloaded.
 */
private class Geary.ImapEngine.EmailPrefetcher : BaseObject,
    Logging.Source {


    public const int PREFETCH_DELAY_SEC = 1;

    // Specify PROPERTIES so messages can be pre-fetched
    // smallest first, ONLY_INCOMPLETE since complete messages
    // don't need re-fetching, and PARTIAL_OK so that messages
    // that don't have properties (i.e. are essentially blank)
    // are still found and filled in.
    private const Geary.Email.Field PREPARE_FIELDS = PROPERTIES;
    private const ImapDB.Folder.LoadFlags PREPARE_FLAGS = (
        ONLY_INCOMPLETE | PARTIAL_OK
    );

    private const Geary.Email.Field PREFETCH_FIELDS = Geary.Email.Field.ALL;
    private const int PREFETCH_CHUNK_BYTES = 512 * 1024;

    public Nonblocking.Semaphore active_lock {
        get; private set; default = new Nonblocking.Semaphore(null);
    }

    /** {@inheritDoc} */
    public Logging.Source? logging_parent {
        get { return this.folder; }
    }

    private weak ImapEngine.MinimalFolder folder;
    private Nonblocking.Mutex mutex = new Nonblocking.Mutex();
    private Gee.TreeSet<Geary.Email> prefetch_emails = new Gee.TreeSet<Geary.Email>(
        Email.compare_recv_date_descending);
    private TimeoutManager prefetch_timer;
    private Cancellable running = new GLib.Cancellable();


    public EmailPrefetcher(ImapEngine.MinimalFolder folder, int start_delay_sec = PREFETCH_DELAY_SEC) {
        this.folder = folder;

        if (start_delay_sec <= 0) {
            start_delay_sec = PREFETCH_DELAY_SEC;
        }

        this.prefetch_timer = new TimeoutManager.seconds(
            start_delay_sec, () => { do_prefetch_async.begin(); }
        );

        // Initially stopped
        this.running.cancel();

        this.folder.email_appended.connect(on_local_expansion);
        this.folder.email_inserted.connect(on_local_expansion);
    }

    public void open() {
        if (this.running.is_cancelled()) {
            this.running = new Cancellable();

            this.active_lock.reset();
            this.do_prepare_all_local_async.begin();
        }
    }

    public void close() {
        if (!this.running.is_cancelled()) {
            this.running.cancel();
            this.prefetch_timer.reset();

            this.active_lock.blind_notify();
        }
    }

    /** {@inheritDoc} */
    public Logging.State to_logging_state() {
        return new Logging.State(
            this,
            "running: %s, queued email: %d, locked: %s",
            (!this.running.is_cancelled()).to_string(),
            prefetch_emails.size,
            (!this.active_lock.can_pass).to_string()
        );
    }

    private void on_local_expansion(Gee.Collection<Geary.EmailIdentifier> ids) {
        if (!this.running.is_cancelled()) {
            this.active_lock.reset();
            this.do_prepare_new_async.begin(ids);
        }
    }

    private void schedule_prefetch(Gee.Collection<Geary.Email>? emails) {
        if (emails != null && emails.size > 0) {
            this.prefetch_emails.add_all(emails);
            this.prefetch_timer.start();
        } else {
            this.active_lock.blind_notify();
        }
    }

    private async void do_prepare_all_local_async() {
        Gee.List<Geary.Email>? list = null;
        try {
            list = yield this.folder.local_folder.list_email_by_id_async(
                null, int.MAX,
                PREPARE_FIELDS,
                PREPARE_FLAGS,
                this.running
            );
        } catch (GLib.IOError.CANCELLED err) {
            // all good
        } catch (GLib.Error err) {
            warning("Error listing email on open: %s", err.message);
        }

        debug("Scheduling %d local messages on open for prefetching",
              list != null ? list.size : 0);
        schedule_prefetch(list);
    }

    private async void do_prepare_new_async(Gee.Collection<Geary.EmailIdentifier> ids) {
        Gee.Set<Geary.Email> list = null;
        try {
            list = yield this.folder.local_folder.list_email_by_sparse_id_async(
                (Gee.Collection<ImapDB.EmailIdentifier>) ids,
                PREPARE_FIELDS,
                PREPARE_FLAGS,
                false,
                this.running
            );
        } catch (GLib.IOError.CANCELLED err) {
            // all good
        } catch (GLib.Error err) {
            warning("Error listing email on open: %s", err.message);
        }

        debug("Scheduling %d new emails for prefetching",
              list != null ? list.size : 0);
        schedule_prefetch(list);
    }

    private async void do_prefetch_async() {
        int token = Nonblocking.Mutex.INVALID_TOKEN;
        try {
            token = yield mutex.claim_async(this.running);
            yield do_prefetch_batch_async();
        } catch (Error err) {
            if (!(err is IOError.CANCELLED))
                debug("Error prefetching emails: %s", err.message);
        }

        // this round is done
        this.active_lock.blind_notify();

        if (token != Nonblocking.Mutex.INVALID_TOKEN) {
            try {
                mutex.release(ref token);
            } catch (GLib.Error release_err) {
                warning("Unable to release mutex: %s", release_err.message);
            }
        }
    }

    private async void do_prefetch_batch_async() throws Error {
        // snarf up all requested Emails for this round
        Gee.TreeSet<Geary.Email> emails = prefetch_emails;
        prefetch_emails = new Gee.TreeSet<Geary.Email>(Email.compare_recv_date_descending);

        if (emails.size == 0)
            return;

        debug("Processing batch, size: %d", emails.size);

        // Big TODO: The engine needs to be able to synthesize
        // ENVELOPE (and any of the fields constituting it) from
        // HEADER if available.  When it can do that won't need to
        // prefetch ENVELOPE; prefetching HEADER will be enough.

        // Another big TODO: The engine needs to be able to chunk BODY
        // requests so a large email doesn't monopolize the pipe and
        // prevent other requests from going through

        Gee.HashSet<EmailIdentifier> chunk = new Gee.HashSet<EmailIdentifier>();
        Gee.HashSet<EmailIdentifier> blanks = new Gee.HashSet<EmailIdentifier>();
        int64 chunk_bytes = 0;
        int count = 0;

        while (emails.size > 0) {
            // dequeue emails by date received, newest to oldest
            Geary.Email email = emails.first();

            if (email.properties == null) {
                // There's no properties, so there's no idea how large
                // the message is. Do these one at a time at the end.
                emails.remove(email);
                blanks.add(email.id);
            } else if (email.properties.total_bytes < PREFETCH_CHUNK_BYTES ||
                       chunk.size == 0) {
                // Add email that is smaller than one chunk or there's
                // nothing in this chunk so far ... this means an
                // oversized email will be pulled all by itself in the
                // next round if there's stuff already ahead of it
                emails.remove(email);
                chunk.add(email.id);
                chunk_bytes += email.properties.total_bytes;
                count++;

                if (chunk_bytes < PREFETCH_CHUNK_BYTES) {
                    continue;
                }
            }

            bool keep_going = yield do_prefetch_email_async(
                chunk, chunk_bytes
            );

            // clear out for next chunk ... this also prevents the
            // final prefetch_async() from trying to pull twice if
            // !keep_going
            chunk.clear();
            chunk_bytes = 0;

            if (!keep_going) {
                break;
            }

            yield Scheduler.sleep_ms_async(200);
        }

        // Finish of any remaining
        if (chunk.size > 0) {
            yield do_prefetch_email_async(chunk, chunk_bytes);
        }
        foreach (EmailIdentifier id in blanks) {
            yield do_prefetch_email_async(Collection.single(id), -1);
        }

        debug("Finished processing batch: %d", count);
    }

    // Return true to continue, false to stop prefetching (cancelled or not open)
    private async bool do_prefetch_email_async(Gee.Collection<EmailIdentifier> ids,
                                               int64 chunk_bytes) {
        debug("Prefetching %d emails (%sb)", ids.size, chunk_bytes.to_string());
        var success = true;
        var cancellable = this.running;

        try {
            Imap.FolderSession remote = yield this.folder.claim_remote_session(
                cancellable
            );

            Gee.Collection<Imap.UID> uids = ImapDB.EmailIdentifier.to_uids(
                (Gee.Collection<ImapDB.EmailIdentifier>) ids
            );
            Gee.Collection<Imap.MessageSet> message_sets =
                Imap.MessageSet.uid_sparse(uids);
            foreach (var message_set in message_sets) {
                Gee.List<Email>? email = yield remote.list_email_async(
                    message_set,
                    PREFETCH_FIELDS,
                    cancellable
                );
                if (email != null && !email.is_empty) {
                    yield this.folder.local_folder.create_or_merge_email_async(
                        email,
                        true,
                        this.folder.harvester,
                        cancellable
                    );
                }
            }
        } catch (GLib.IOError.CANCELLED err) {
            // fine
        } catch (EngineError.SERVER_UNAVAILABLE err) {
            // fine
            debug("Error prefetching %d emails: %s", ids.size, err.message);
        } catch (GLib.Error err) {
            // not fine
            success = false;
            warning("Error prefetching %d emails: %s", ids.size, err.message);
        }

        return success;
    }
}
