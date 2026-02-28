// Developing and Running Widgets Locally

// This project’s Widget Extension contains multiple widgets. Xcode requires you to tell it which widget to run when you press Run. Use per-widget schemes with environment variables.

// ## Schemes per widget (best practice)
// Create two schemes (or more as needed), each targeting the Widget Extension:

// - Scheme: TaskHubWidget (Home)
//   - Edit Scheme… → Run → Arguments → Environment Variables:
//     - _XCWidgetKind = com.ie.taskhub.widget.home
//     - __WidgetKind = com.ie.taskhub.widget.home
//     - _XCWidgetDefaultView = gallery
//     - (Optional) _XCWidgetFamily = systemMedium

// - Scheme: TaskHubWidget (Control)
//   - Edit Scheme… → Run → Arguments → Environment Variables:
//     - _XCWidgetKind = com.ie.taskhub.widget.control
//     - __WidgetKind = com.ie.taskhub.widget.control
//     - _XCWidgetDefaultView = gallery
//     - (Optional) _XCWidgetFamily = systemSmall

// Enable the checkbox next to each variable.

// Tip: Manage Schemes… → check “Shared” so the team/CI can use the same setup.

// ## Why this is required
// When a Widget Extension includes more than one widget, the system needs the widget “kind” to know which one to launch under the debugger. If not provided, you’ll see an error similar to:

// "Invalid requested widget kind... Please specify one of: 'com.ie.taskhub.widget.home', 'com.ie.taskhub.widget.control'"

// ## Widget kinds in this project
// - Home Screen widget kind: com.ie.taskhub.widget.home
// - Control widget kind: com.ie.taskhub.widget.control
// - Debug-only legacy alias (for local compatibility): com.ie.taskhub.widget

// ## Notes
// - The Widget Extension uses a single @main WidgetBundle, which is the recommended structure.
// - Keep previews under #if DEBUG in widget view files to avoid shipping them.
// - If you want to temporarily run only one widget without setting schemes, you can comment out the others in TaskHubWidgetExtensionBundle.swift, but using schemes is preferred.
