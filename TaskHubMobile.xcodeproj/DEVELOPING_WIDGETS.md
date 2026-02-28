// Developing and Running Widgets Locally

// This project’s Widget Extension contains multiple widgets. Xcode requires you to tell it which widget to run when you press Run. Use per-widget schemes with environment variables.

// ## Schemes per widget (best practice)
// Create two schemes (or more as needed), each targeting the Widget Extension:

// - Scheme: TaskHubWidget (Home)
//   - Edit Scheme… → Run → Arguments → Environment Variables:
//     - _XCWidgetKind = com.ie.taskhub.widget
//     - (Optional) _XCWidgetFamily = systemMedium

// - Scheme: TaskHubWidget (Control)
//   - Edit Scheme… → Run → Arguments → Environment Variables:
//     - _XCWidgetKind = com.ie.TaskHubMobile.TaskHubWidgetExtension
//     - (Optional) _XCWidgetFamily = systemSmall

// Enable the checkbox next to each variable.

// Tip: Manage Schemes… → check “Shared” so the team/CI can use the same setup.

// ## Why this is required
// When a Widget Extension includes more than one widget, the system needs the widget “kind” to know which one to launch under the debugger. If not provided, you’ll see an error similar to:

// "Please specify the widget kind in the scheme's Environment Variables using the key '_XCWidgetKind' to be one of: 'com.ie.taskhub.widget','com.ie.TaskHubMobile.TaskHubWidgetExtension'"

// ## Widget kinds in this project
// - Home Screen widget kind: com.ie.taskhub.widget
// - Control widget kind: com.ie.TaskHubMobile.TaskHubWidgetExtension

// ## Notes
// - The Widget Extension uses a single @main WidgetBundle, which is the recommended structure.
// - Keep previews under #if DEBUG in widget view files to avoid shipping them.
// - If you want to temporarily run only one widget without setting schemes, you can comment out the others in TaskHubWidgetExtensionBundle.swift, but using schemes is preferred.

