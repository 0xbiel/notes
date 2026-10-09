# SwiftMath in Palladium

Vendored from https://github.com/mgriebling/SwiftMath at tag 1.7.3,
commit fa8244ed032f4a1ade4cb0571bf87d2f1a9fd2d7, under the included MIT license.
Font licenses remain in Sources/SwiftMath/mathFonts.bundle.

Local patch: MathResourceBundle checks the signed macOS app's Contents/Resources
before falling back to SwiftPM's resource accessor. MTFont and MathFont use this
locator. The upstream test target is omitted from this vendored package. This lets packaged Palladium render offline without depending on the
checkout's build directory; no other upstream implementation has been changed.
