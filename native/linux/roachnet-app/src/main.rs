use adw::prelude::*;
use gtk::prelude::*;

fn main() {
    let app = adw::Application::builder()
        .application_id("com.roachwares.roachnet")
        .build();

    app.connect_activate(build_ui);
    app.run();
}

fn build_ui(app: &adw::Application) {
    roachnet_design::apply_global_css();

    let root = gtk::Box::new(gtk::Orientation::Horizontal, 0);

    let sidebar = gtk::Box::new(gtk::Orientation::Vertical, 16);
    sidebar.set_width_request(280);
    sidebar.set_margin_top(24);
    sidebar.set_margin_bottom(24);
    sidebar.set_margin_start(24);
    sidebar.set_margin_end(24);

    let brand = gtk::Label::new(Some("ROACHNET"));
    brand.add_css_class("roach-kicker");
    brand.set_halign(gtk::Align::Start);
    sidebar.append(&brand);

    let nav_items = gtk::Box::new(gtk::Orientation::Vertical, 8);
    for label in ["Overview", "RoachClaw", "Knowledge", "Runtime"] {
        let button = gtk::Button::with_label(label);
        button.add_css_class("pill");
        nav_items.append(&button);
    }
    sidebar.append(&nav_items);

    let content = gtk::Box::new(gtk::Orientation::Vertical, 18);
    content.set_hexpand(true);
    content.set_margin_top(28);
    content.set_margin_bottom(28);
    content.set_margin_start(0);
    content.set_margin_end(28);

    let hero = roachnet_design::make_panel_box();

    let title = gtk::Label::new(Some("One local command center."));
    title.add_css_class("roach-title");
    title.set_wrap(true);
    title.set_halign(gtk::Align::Start);

    let subtitle = gtk::Label::new(Some("RoachClaw, runtime, and knowledge in one native workspace."));
    subtitle.add_css_class("roach-subtle");
    subtitle.set_halign(gtk::Align::Start);

    hero.append(&title);
    hero.append(&subtitle);

    content.append(&hero);
    root.append(&sidebar);
    root.append(&content);

    let window = adw::ApplicationWindow::builder()
        .application(app)
        .title("RoachNet")
        .default_width(1380)
        .default_height(900)
        .content(&root)
        .build();

    window.present();
}
