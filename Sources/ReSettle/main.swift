import AppKit

let arguments = CommandLine.arguments

if arguments.contains("--dump") {
    Diagnostics.run()
    exit(0)
}

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    ReSettle — put your windows back where they belong after the displays wake up.

    Usage:
      ReSettle            run the menu bar app
      ReSettle --dump     print displays, remembered profiles and live windows
      ReSettle --help     this text
    """)
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
