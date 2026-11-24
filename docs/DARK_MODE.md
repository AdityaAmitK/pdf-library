# Forced PDF dark mode

A reader setting, separate from the app's own Appearance setting (System, Light, Dark) (default off, persisted, independent of the system appearance) that shows PDFs on a dark surface with light text while every image and piece of artwork keeps its original colors. The PDF file is never changed.

## Why not a filter

PDFKit and Core Graphics have no option to recolor only text. Inverting the page, applying a color filter or thresholding pixels would also change photos and artwork, so none of those are used.

## How it works

`ReaderDocument` makes PDFKit create `ReaderPage` objects. With dark mode on, `ReaderPage.draw(with:to:)` paints the dark surface and draws a recolored copy of the page instead of the original. PDFView itself is unchanged, so zoom, scrolling, selection, search, links, page tracking and position restore behave as usual.

The recolored copy (`DarkPageBuilder`) is a one-page PDF built in memory:

1. The resources the page's content actually names (fonts, images, artwork, form XObjects) are copied object for object through Core Graphics' PDF object model. Forms used as soft masks are copied byte-for-byte, because their luminance defines opacity.
2. The page's content stream, and each form XObject's, is rewritten by `TextRecolorRewriter`. It works on drawing operators, not pixels. Inside each text object (`BT`…`ET`) color operators are replaced by a light color with the same hue (black → near-white, dark blue → light blue; already-light text is unchanged). The text object is wrapped in `q`/`Q` and the original color and text state are replayed afterwards, so all following artwork draws exactly as before.
3. A plain white (near-neutral), unclipped, axis-aligned rectangle covering the whole page and painted before anything else (the document's own page background) is painted as the dark surface instead. Any other light rectangle is artwork and keeps its color.

The copy is drawn in the page's own coordinate space (honouring /Rotate and offset crop boxes). Pages are built lazily, on PDFKit's render threads, and the eight most recent are cached.

## Faithful handling and visible limits

- **Scans.** A page that draws images but no PDF text is drawn as the original. Text that is part of an image stays part of the image, in original colors. Invisible OCR text (render mode 3) stays invisible. The reader notes "Scanned page" on such pages.
- **Shown in original colors, with a note on the page:** fax-encoded images (CCITT, JBIG2), optional content layers (their visibility lives in the source catalog), Type 3 font glyphs that set their own colors (`d0`), and pages whose drawing instructions can't be decoded or parsed (including an invalid text render mode).
- **Clipping text inside a form XObject** whose color is inherited from the caller keeps its original color, because that color can't be restored afterwards.
- **Text on light boxes** (shaded table cells, callouts drawn as artwork) becomes light text on the original light box, and the reader shows a note on that page. A page whose text sits on a light, non-white page-sized fill (cream, grey, a panel) is shown in its original colors with a note, since recolored text would be unreadable there.
- **Annotations** (form fields, highlights, notes) draw in their original colors on top.
- **Spot and pattern text colors** that can't be resolved become light gray.

## Manual check

See the forced dark mode section of RUNBOOK.md. The synthetic sample used for that check has a text page with a color photo, a vector artwork page, an image-only page and plain text pages.
