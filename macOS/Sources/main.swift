import AppKit

let app = NSApplication.shared
#if SLIDESHOW_QA
let library: any SlideshowLibrary = FixtureLibrary()
#else
let library: any SlideshowLibrary = PhotoLibrary()
#endif
let delegate = SlideshowApp(library: library)
app.delegate = delegate
app.run()
