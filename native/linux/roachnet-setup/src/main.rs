use adw::prelude::*;
use gtk::prelude::*;

fn main() {
    let app = adw::Application::builder()
        .application_id("com.roachwares.roachnet.setup")
        .build();

    app.connect_activate(build_ui);
    app.run();
}

fn build_ui(app: &adw::Application) {
    roachnet_design::apply_global_css();

    let panel = roachnet_design::make_panel_box();

    let kicker = gtk::Label::new(Some("ROACHNET SETUP"));
    kicker.add_css_class("roach-kicker");
    kicker.set_halign(gtk::Align::Start);

    let title = gtk::Label::new(Some("Set up RoachNet."));
    title.add_css_class("roach-title");
    title.set_wrap(true);
    title.set_halign(gtk::Align::Start);

    let subtitle = gtk::Label::new(Some("One guided install."));
    subtitle.add_css_class("roach-subtle");
    subtitle.set_halign(gtk::Align::Start);

    let pill_row = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    for label in ["Welcome", "Machine", "Runtime", "RoachClaw"] {
        let chip = gtk::Label::new(Some(label));
        chip.add_css_class("roach-subtle");
        let shell = gtk::Frame::new(None);
        shell.add_css_class("roach-raised");
        shell.set_child(Some(&chip));
        pill_row.append(&shell);
    }

    panel.append(&kicker);
    panel.append(&title);
    panel.append(&subtitle);
    panel.append(&pill_row);

    let content = gtk::Box::new(gtk::Orientation::Vertical, 0);
    content.set_margin_top(28);
    content.set_margin_bottom(28);
    content.set_margin_start(28);
    content.set_margin_end(28);
    content.append(&panel);

    let window = adw::ApplicationWindow::builder()
        .application(app)
        .title("RoachNet Setup")
        .default_width(1080)
        .default_height(760)
        .content(&content)
        .build();

    window.present();
}
