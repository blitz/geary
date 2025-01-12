/* Copyright 2016 Software Freedom Conservancy Inc.
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution.
 */

// Stores formatted data for a message.
public class FormattedConversationData : Geary.BaseObject {
    struct Participants {
        string? markup;

        // markup may look different depending on whether widget is selected
        bool was_widget_selected;
    }

    public const int SPACING = 6;

    private const string ME = _("Me");
    private const string STYLE_EXAMPLE = "Gg"; // Use both upper and lower case to get max height.
    private const int TEXT_LEFT = SPACING * 2 + IconFactory.UNREAD_ICON_SIZE;
    private const double DIM_TEXT_AMOUNT = 0.05;
    private const double DIM_PREVIEW_TEXT_AMOUNT = 0.25;


    private class ParticipantDisplay : Geary.BaseObject, Gee.Hashable<ParticipantDisplay> {
        public Geary.RFC822.MailboxAddress address;
        public bool is_unread;

        public ParticipantDisplay(Geary.RFC822.MailboxAddress address, bool is_unread) {
            this.address = address;
            this.is_unread = is_unread;
        }

        public string get_full_markup(Gee.List<Geary.RFC822.MailboxAddress> account_mailboxes) {
            return get_as_markup((address in account_mailboxes) ? ME : address.to_short_display());
        }

        public string get_short_markup(Gee.List<Geary.RFC822.MailboxAddress> account_mailboxes) {
            if (address in account_mailboxes)
                return get_as_markup(ME);

            if (address.is_spoofed()) {
                return get_full_markup(account_mailboxes);
            }

            string short_address = Markup.escape_text(address.to_short_display());

            if (", " in short_address) {
                // assume address is in Last, First format
                string[] tokens = short_address.split(", ", 2);
                short_address = tokens[1].strip();
                if (Geary.String.is_empty(short_address))
                    return get_full_markup(account_mailboxes);
            }

            // use first name as delimited by a space
            string[] tokens = short_address.split(" ", 2);
            if (tokens.length < 1)
                return get_full_markup(account_mailboxes);

            string first_name = tokens[0].strip();
            if (Geary.String.is_empty_or_whitespace(first_name))
                return get_full_markup(account_mailboxes);

            return get_as_markup(first_name);
        }

        private string get_as_markup(string participant) {
            string markup = Geary.HTML.escape_markup(participant);

            if (is_unread) {
                markup = "<b>%s</b>".printf(markup);
            }

            if (this.address.is_spoofed()) {
                markup = "<s>%s</s>".printf(markup);
            }

            return markup;
        }

        public bool equal_to(ParticipantDisplay other) {
            return address.equal_to(other.address)
                && address.name == other.address.name;
        }

        public uint hash() {
            return address.hash();
        }
    }

    private static int cell_height = -1;
    private static int preview_height = -1;

    public bool is_unread { get; set; }
    public bool is_flagged { get; set; }
    public string date { get; private set; }
    public string? body { get; private set; default = null; } // optional
    public int num_emails { get; set; }
    public Geary.Email? preview { get; private set; default = null; }

    private Application.Configuration config;

    private Gtk.Settings? gtk;
    private Pango.FontDescription font;

    private Geary.App.Conversation? conversation = null;
    private Gee.List<Geary.RFC822.MailboxAddress>? account_owner_emails = null;
    private bool use_to = true;
    private CountBadge count_badge = new CountBadge(2);
    private string subject_html_escaped;
    private Participants participants = Participants(){markup = null};

    // Creates a formatted message data from an e-mail.
    public FormattedConversationData(Application.Configuration config,
                                     Geary.App.Conversation conversation,
                                     Geary.Email preview,
                                     Gee.List<Geary.RFC822.MailboxAddress> account_owner_emails) {
        this.config = config;
        this.gtk = Gtk.Settings.get_default();
        this.conversation = conversation;
        this.account_owner_emails = account_owner_emails;
        this.use_to = conversation.base_folder.used_as.is_outgoing();

        this.gtk.notify["gtk-font-name"].connect(this.update_font);
        update_font();

        // Load preview-related data.
        update_date_string();
        this.subject_html_escaped
            = Geary.HTML.escape_markup(Util.Email.strip_subject_prefixes(preview));
        this.body = Geary.String.reduce_whitespace(preview.get_preview_as_string());
        this.preview = preview;

        // Load conversation-related data.
        this.is_unread = conversation.is_unread();
        this.is_flagged = conversation.is_flagged();
        this.num_emails = conversation.get_count();

        // todo: instead of clearing the cache update it
        this.conversation.appended.connect(clear_participants_cache);
        this.conversation.trimmed.connect(clear_participants_cache);
        this.conversation.email_flags_changed.connect(clear_participants_cache);
    }

    // Creates an example message (used internally for styling calculations.)
    public FormattedConversationData.create_example(Application.Configuration config) {
        this.config = config;
        this.is_unread = false;
        this.is_flagged = false;
        this.date = STYLE_EXAMPLE;
        this.subject_html_escaped = STYLE_EXAMPLE;
        this.body = STYLE_EXAMPLE + "\n" + STYLE_EXAMPLE;
        this.num_emails = 1;

        this.font = Pango.FontDescription.from_string(
            this.config.gnome_interface.get_string("font-name")
        );
    }

    private void clear_participants_cache(Geary.Email email) {
        participants.markup = null;
    }

    public bool update_date_string() {
        // get latest email *in folder* for the conversation's date, fall back on out-of-folder
        Geary.Email? latest = conversation.get_latest_recv_email(Geary.App.Conversation.Location.IN_FOLDER_OUT_OF_FOLDER);
        if (latest == null || latest.properties == null)
            return false;

        // conversation list store sorts by date-received, so display that instead of sender's
        // Date:
        string new_date = Util.Date.pretty_print(
            latest.properties.date_received.to_local(),
            this.config.clock_format
        );
        if (new_date == date)
            return false;

        date = new_date;

        return true;
    }

    private uint8 gdk_to_rgb(double gdk) {
        return (uint8) (gdk.clamp(0.0, 1.0) * 255.0);
    }

    private Gdk.RGBA dim_rgba(Gdk.RGBA rgba, double amount) {
        amount = amount.clamp(0.0, 1.0);

        // can't use ternary in struct initializer due to this bug:
        // https://bugzilla.gnome.org/show_bug.cgi?id=684742
        double dim_red = (rgba.red >= 0.5) ? -amount : amount;
        double dim_green = (rgba.green >= 0.5) ? -amount : amount;
        double dim_blue = (rgba.blue >= 0.5) ? -amount : amount;

        return Gdk.RGBA() {
            red = (rgba.red + dim_red).clamp(0.0, 1.0),
            green = (rgba.green + dim_green).clamp(0.0, 1.0),
            blue = (rgba.blue + dim_blue).clamp(0.0, 1.0),
            alpha = rgba.alpha
        };
    }

    private string rgba_to_markup(Gdk.RGBA rgba) {
        return "#%02x%02x%02x".printf(
            gdk_to_rgb(rgba.red), gdk_to_rgb(rgba.green), gdk_to_rgb(rgba.blue));
    }

    private Gdk.RGBA get_foreground_rgba(Gtk.Widget widget, bool selected) {
        // Do the https://bugzilla.gnome.org/show_bug.cgi?id=763796 dance
        Gtk.StyleContext context = widget.get_style_context();
        context.save();
        context.set_state(
            selected ? Gtk.StateFlags.SELECTED : Gtk.StateFlags.NORMAL
        );
        Gdk.RGBA colour = context.get_color(context.get_state());
        context.restore();
        return colour;
    }

    private string get_participants_markup(Gtk.Widget widget, bool selected) {
        if (participants.markup != null && participants.was_widget_selected == selected)
            return participants.markup;

        if (conversation == null || account_owner_emails == null || account_owner_emails.size == 0)
            return "";

        // Build chronological list of unique AuthorDisplay records, setting to
        // unread if any message by that author is unread
        Gee.ArrayList<ParticipantDisplay> list = new Gee.ArrayList<ParticipantDisplay>();
        foreach (Geary.Email message in conversation.get_emails(Geary.App.Conversation.Ordering.RECV_DATE_ASCENDING)) {
            // only display if something to display
            Geary.RFC822.MailboxAddresses? addresses = use_to
                ? new Geary.RFC822.MailboxAddresses.single(Util.Email.get_primary_originator(message))
                : message.from;
            if (addresses == null || addresses.size < 1)
                continue;

            foreach (Geary.RFC822.MailboxAddress address in addresses) {
                ParticipantDisplay participant_display = new ParticipantDisplay(address,
                    message.email_flags.is_unread());

                int existing_index = list.index_of(participant_display);
                if (existing_index < 0) {
                    list.add(participant_display);

                    continue;
                }

                // if present and this message is unread but the prior were read,
                // this author is now unread
                if (message.email_flags.is_unread())
                    list[existing_index].is_unread = true;
            }
        }

        if (list.size == 1) {
            // if only one participant, use full name
            participants.markup = "<span foreground='%s'>%s</span>"
                .printf(rgba_to_markup(get_foreground_rgba(widget, selected)),
                        list[0].get_full_markup(account_owner_emails));
        } else {
            StringBuilder builder = new StringBuilder("<span foreground='%s'>".printf(
                rgba_to_markup(get_foreground_rgba(widget, selected))));
            bool first = true;
            foreach (ParticipantDisplay participant in list) {
                if (!first)
                    builder.append(", ");

                builder.append(participant.get_short_markup(account_owner_emails));
                first = false;
            }
            builder.append("</span>");
            participants.markup = builder.str;
        }
        participants.was_widget_selected = selected;
        return participants.markup;
    }

    public void render(Cairo.Context ctx, Gtk.Widget widget, Gdk.Rectangle background_area,
        Gdk.Rectangle cell_area, Gtk.CellRendererState flags, bool hover_select) {
        render_internal(widget, cell_area, ctx, flags, false, hover_select);
    }

    // Call this on style changes.
    public void calculate_sizes(Gtk.Widget widget) {
        render_internal(widget, null, null, 0, true, false);
    }

    // Must call calculate_sizes() first.
    public int get_height() {
        assert(cell_height != -1); // ensures calculate_sizes() was called.
        return cell_height;
    }

    // Can be used for rendering or calculating height.
    private void render_internal(Gtk.Widget widget, Gdk.Rectangle? cell_area,
        Cairo.Context? ctx, Gtk.CellRendererState flags, bool recalc_dims,
        bool hover_select) {
        bool display_preview = this.config.display_preview;
        int y = SPACING + (cell_area != null ? cell_area.y : 0);

        bool selected = (flags & Gtk.CellRendererState.SELECTED) != 0;
        bool hover = (flags & Gtk.CellRendererState.PRELIT) != 0 || (selected && hover_select);

        // Date field.
        Pango.Rectangle ink_rect = render_date(widget, cell_area, ctx, y, selected);

        // From field.
        ink_rect = render_from(widget, cell_area, ctx, y, selected, ink_rect);
        y += ink_rect.height + ink_rect.y + SPACING;

        // If we are displaying a preview then the message counter goes on the same line as the
        // preview, otherwise it is with the subject.
        int preview_height = 0;

        // Setup counter badge.
        count_badge.count = num_emails;
        int counter_width = count_badge.get_width(widget) + SPACING;
        int counter_x = cell_area != null ? cell_area.width - cell_area.x - counter_width +
            (SPACING / 2) : 0;

        if (display_preview) {
            // Subject field.
            render_subject(widget, cell_area, ctx, y, selected);
            y += ink_rect.height + ink_rect.y + (SPACING / 2);

            // Number of e-mails field.
            count_badge.render(widget, ctx, counter_x, y + (SPACING / 2), selected);

            // Body preview.
            ink_rect = render_preview(widget, cell_area, ctx, y, selected, counter_width);
            preview_height = ink_rect.height + ink_rect.y + (int) (SPACING * 1.2);
        } else {
            // Number of e-mails field.
            count_badge.render(widget, ctx, counter_x, y, selected);

            // Subject field.
            render_subject(widget, cell_area, ctx, y, selected, counter_width);
            y += ink_rect.height + ink_rect.y + (int) (SPACING * 1.2);
        }

        if (recalc_dims) {
            FormattedConversationData.preview_height = preview_height;
            FormattedConversationData.cell_height = y + preview_height;
        } else {
            int unread_y = display_preview ? cell_area.y + SPACING * 2 : cell_area.y +
                SPACING;

            // Unread indicator.
            if (is_unread || hover) {
                Gdk.Pixbuf read_icon = IconFactory.instance.load_symbolic(
                    is_unread ? "mail-unread-symbolic" : "mail-read-symbolic",
                    IconFactory.UNREAD_ICON_SIZE, widget.get_style_context());
                Gdk.cairo_set_source_pixbuf(ctx, read_icon, cell_area.x + SPACING, unread_y);
                ctx.paint();
            }

            // Starred indicator.
            if (is_flagged || hover) {
                int star_y = cell_area.y + (cell_area.height / 2) + (display_preview ? SPACING : 0);
                Gdk.Pixbuf starred_icon = IconFactory.instance.load_symbolic(
                    is_flagged ? "starred-symbolic" : "non-starred-symbolic",
                    IconFactory.STAR_ICON_SIZE, widget.get_style_context());
                Gdk.cairo_set_source_pixbuf(ctx, starred_icon, cell_area.x + SPACING, star_y);
                ctx.paint();
            }
        }
    }

    private Pango.Rectangle render_date(Gtk.Widget widget, Gdk.Rectangle? cell_area,
        Cairo.Context? ctx, int y, bool selected) {
        string date_markup = "<span size='smaller' foreground='%s'>%s</span>".printf(
            rgba_to_markup(dim_rgba(get_foreground_rgba(widget, selected), DIM_TEXT_AMOUNT)),
            Geary.HTML.escape_markup(date));

        Pango.Rectangle? ink_rect;
        Pango.Rectangle? logical_rect;
        Pango.Layout layout_date = widget.create_pango_layout(null);
        layout_date.set_font_description(this.font);
        layout_date.set_markup(date_markup, -1);
        layout_date.set_alignment(Pango.Alignment.RIGHT);
        layout_date.get_pixel_extents(out ink_rect, out logical_rect);
        if (ctx != null && cell_area != null) {
            ctx.move_to(cell_area.width - cell_area.x - ink_rect.width - ink_rect.x - SPACING, y);
            Pango.cairo_show_layout(ctx, layout_date);
        }
        return ink_rect;
    }

    private Pango.Rectangle render_from(Gtk.Widget widget, Gdk.Rectangle? cell_area,
        Cairo.Context? ctx, int y, bool selected, Pango.Rectangle ink_rect) {
        string from_markup = (conversation != null) ? get_participants_markup(widget, selected) : STYLE_EXAMPLE;

        Pango.FontDescription font = this.font;
        if (is_unread) {
            font = font.copy();
            font.set_weight(Pango.Weight.BOLD);
        }
        Pango.Layout layout_from = widget.create_pango_layout(null);
        layout_from.set_font_description(font);
        layout_from.set_markup(from_markup, -1);
        layout_from.set_ellipsize(Pango.EllipsizeMode.END);
        if (ctx != null && cell_area != null) {
            layout_from.set_width((cell_area.width - ink_rect.width - ink_rect.x - (SPACING * 3) -
                TEXT_LEFT)
            * Pango.SCALE);
            ctx.move_to(cell_area.x + TEXT_LEFT, y);
            Pango.cairo_show_layout(ctx, layout_from);
        }
        return ink_rect;
    }

    private void render_subject(Gtk.Widget widget, Gdk.Rectangle? cell_area, Cairo.Context? ctx,
        int y, bool selected, int counter_width = 0) {
        string subject_markup = "<span size='smaller' foreground='%s'>%s</span>".printf(
            rgba_to_markup(dim_rgba(get_foreground_rgba(widget, selected), DIM_TEXT_AMOUNT)),
            subject_html_escaped);

        Pango.FontDescription font = this.font;
        if (is_unread) {
            font = font.copy();
            font.set_weight(Pango.Weight.BOLD);
        }
        Pango.Layout layout_subject = widget.create_pango_layout(null);
        layout_subject.set_font_description(font);
        layout_subject.set_markup(subject_markup, -1);
        if (cell_area != null)
            layout_subject.set_width((cell_area.width - TEXT_LEFT - counter_width) * Pango.SCALE);
        layout_subject.set_ellipsize(Pango.EllipsizeMode.END);
        if (ctx != null && cell_area != null) {
            ctx.move_to(cell_area.x + TEXT_LEFT, y);
            Pango.cairo_show_layout(ctx, layout_subject);
        }
    }

    private Pango.Rectangle render_preview(Gtk.Widget widget, Gdk.Rectangle? cell_area,
        Cairo.Context? ctx, int y, bool selected, int counter_width = 0) {
        double dim = selected ? DIM_TEXT_AMOUNT : DIM_PREVIEW_TEXT_AMOUNT;
        string preview_markup = "<span size='smaller' foreground='%s'>%s</span>".printf(
            rgba_to_markup(dim_rgba(get_foreground_rgba(widget, selected), dim)),
            Geary.String.is_empty(body) ? "" : Geary.HTML.escape_markup(body));

        Pango.Layout layout_preview = widget.create_pango_layout(null);
        layout_preview.set_font_description(this.font);
        layout_preview.set_markup(preview_markup, -1);
        layout_preview.set_wrap(Pango.WrapMode.WORD);
        layout_preview.set_ellipsize(Pango.EllipsizeMode.END);
        if (ctx != null && cell_area != null) {
            layout_preview.set_width((cell_area.width - TEXT_LEFT - counter_width - SPACING) * Pango.SCALE);
            layout_preview.set_height(preview_height * Pango.SCALE);

            ctx.move_to(cell_area.x + TEXT_LEFT, y);
            Pango.cairo_show_layout(ctx, layout_preview);
        } else {
            layout_preview.set_width(int.MAX);
            layout_preview.set_height(int.MAX);
        }

        Pango.Rectangle? ink_rect;
        Pango.Rectangle? logical_rect;
        layout_preview.get_pixel_extents(out ink_rect, out logical_rect);
        return ink_rect;
    }

    private void update_font() {
        var name = "Cantarell 11";
        if (this.gtk != null) {
            name = this.gtk.gtk_font_name;
        }
        this.font = Pango.FontDescription.from_string(name);
    }

}
