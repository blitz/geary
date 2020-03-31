/* Copyright 2016 Software Freedom Conservancy Inc.
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution.
 */

// A branch that holds all the folders for a particular account.
public class FolderList.AccountBranch : Sidebar.Branch {
    public Geary.Account account { get; private set; }
    public SpecialGrouping user_folder_group { get; private set; }
    public Gee.HashMap<Geary.FolderPath, FolderEntry> folder_entries { get; private set; }

    private string display_name = "";

    public AccountBranch(Geary.Account account) {
        base(new Sidebar.Header(account.information.display_name),
             Sidebar.Branch.Options.AUTO_OPEN_ON_NEW_CHILD, normal_folder_comparator, special_folder_comparator);

        this.account = account;
        user_folder_group = new SpecialGrouping(2, "", "tag-symbolic");
        folder_entries = new Gee.HashMap<Geary.FolderPath, FolderEntry>();

        this.display_name = account.information.display_name;
        account.information.changed.connect(on_information_changed);

        entry_removed.connect(on_entry_removed);
        entry_moved.connect(check_user_folders);
    }

    ~AccountBranch() {
        account.information.changed.disconnect(on_information_changed);
        entry_removed.disconnect(on_entry_removed);
        entry_moved.disconnect(check_user_folders);
    }

    private void on_information_changed() {
        if (this.display_name != this.account.information.display_name) {
            this.display_name = account.information.display_name;
            ((Sidebar.Grouping) get_root()).rename(this.display_name);
        }
    }

    private static int special_grouping_comparator(Sidebar.Entry a, Sidebar.Entry b) {
        SpecialGrouping? grouping_a = a as SpecialGrouping;
        SpecialGrouping? grouping_b = b as SpecialGrouping;

        assert(grouping_a != null || grouping_b != null);

        int position_a = (grouping_a != null ? grouping_a.position : 0);
        int position_b = (grouping_b != null ? grouping_b.position : 0);

        return position_a - position_b;
    }

    private static int special_folder_comparator(Sidebar.Entry a, Sidebar.Entry b) {
        if (a is Sidebar.Grouping || b is Sidebar.Grouping)
            return special_grouping_comparator(a, b);

        FolderEntry entry_a = (FolderEntry) a;
        FolderEntry entry_b = (FolderEntry) b;
        Geary.Folder.SpecialUse type_a = entry_a.folder.used_as;
        Geary.Folder.SpecialUse type_b = entry_b.folder.used_as;

        // Special folders are ordered by their enum value.
        return (int) type_a - (int) type_b;
    }

    private static int normal_folder_comparator(Sidebar.Entry a, Sidebar.Entry b) {
        // Non-special folders are compared based on name.
        return a.get_sidebar_name().collate(b.get_sidebar_name());
    }

    public FolderEntry? get_entry_for_path(Geary.FolderPath folder_path) {
        return folder_entries.get(folder_path);
    }

    public void add_folder(Geary.Folder folder) {
        Sidebar.Entry? graft_point = null;
        FolderEntry folder_entry = new FolderEntry(folder);
        Geary.Folder.SpecialUse used_as = folder.used_as;
        if (used_as != NONE) {
            if (used_as == SEARCH)
                return; // Don't show search folder under the account.

            // Special folders go in the root of the account.
            graft_point = get_root();
        } else if (folder.path.is_top_level) {
            // Top-level folders get put in our special user folders group.
            graft_point = user_folder_group;

            if (!has_entry(user_folder_group)) {
                graft(get_root(), user_folder_group);
            }
        } else {
            Sidebar.Entry? entry = folder_entries.get(folder.path.parent);
            if (entry != null)
                graft_point = entry;
        }

        // Due to how we enumerate folders on the server, it's unfortunately
        // possible now to have two folders that we'd put in the same place in
        // our tree.  In that case, we just ignore the second folder for now.
        // See #6616.
        if (graft_point != null) {
            Sidebar.Entry? twin = find_first_child(graft_point, (e) => {
                return e.get_sidebar_name() == folder_entry.get_sidebar_name();
            });
            if (twin != null)
                graft_point = null;
        }

        if (graft_point != null) {
            graft(graft_point, folder_entry);
            folder_entries.set(folder.path, folder_entry);
        } else {
            debug("Could not add folder %s of type %s to folder list", folder.to_string(),
                  used_as.to_string());
        }
    }

    public void remove_folder(Geary.Folder folder) {
        Sidebar.Entry? entry = folder_entries.get(folder.path);
        if(entry == null) {
            debug("Could not remove folder %s", folder.to_string());
            return;
        }

        prune(entry);
        folder_entries.unset(folder.path);
    }

    private void on_entry_removed(Sidebar.Entry entry) {
        FolderEntry? folder_entry = entry as FolderEntry;
        if (folder_entry != null && folder_entries.has_key(folder_entry.folder.path))
            folder_entries.unset(folder_entry.folder.path);

        check_user_folders(entry);
    }

    private void check_user_folders(Sidebar.Entry entry) {
        if (entry != user_folder_group) {
            // remove "Labels" entry if there are no more user entries
            if (has_entry(user_folder_group) && (get_child_count(user_folder_group) == 0)) {
                prune(user_folder_group);
            }
        }
    }
}
