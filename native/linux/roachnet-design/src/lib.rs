use gtk::prelude::*;

pub const BACKGROUND: &str = "#080A0B";
pub const PANEL: &str = "#121618";
pub const PANEL_RAISED: &str = "#171C1E";
pub const BORDER: &str = "#22282B";
pub const TEXT: &str = "#F4F7F8";
pub const MUTED: &str = "#93A0A5";
pub const GREEN: &str = "#18F577";
pub const MAGENTA: &str = "#C736FA";

pub fn apply_global_css() {
    let provider = gtk::CssProvider::new();
    provider.load_from_data(
        format!(
            r#"
            window {{
                background: {background};
                color: {text};
            }}

            .roach-panel {{
                background: {panel};
                border: 1px solid {border};
                border-radius: 28px;
                padding: 24px;
            }}

            .roach-raised {{
                background: {raised};
                border: 1px solid {border};
                border-radius: 20px;
                padding: 16px;
            }}

            .roach-kicker {{
                color: {green};
                font-size: 12px;
                font-weight: 700;
                letter-spacing: 0.24em;
            }}

            .roach-title {{
                color: {text};
                font-size: 34px;
                font-weight: 700;
            }}

            .roach-subtle {{
                color: {muted};
                font-size: 14px;
                font-weight: 500;
            }}
        "#,
            background = BACKGROUND,
            panel = PANEL,
            raised = PANEL_RAISED,
            border = BORDER,
            text = TEXT,
            muted = MUTED,
            green = GREEN
        ),
    );

    if let Some(display) = gtk::gdk::Display::default() {
        gtk::style_context_add_provider_for_display(
            &display,
            &provider,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    }
}

pub fn make_panel_box() -> gtk::Box {
    let panel = gtk::Box::new(gtk::Orientation::Vertical, 16);
    panel.add_css_class("roach-panel");
    panel
}
