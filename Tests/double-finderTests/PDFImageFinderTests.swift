import XCTest
import PDFKit
@testable import double_finder

/// `PDFImageFinder` walks a page's content stream and reports where image
/// XObjects land (PDF user space), including through `cm` transforms and Form
/// XObjects — the dark-mode renderer pastes those regions back un-inverted.
final class PDFImageFinderTests: XCTestCase {

    /// A one-page PDF drawn with CoreGraphics: a filled rect (vector), one
    /// image at `imageRect`, optionally a second one rotated 90°.
    private func makePDF(imageRect: CGRect, rotatedImage: Bool = false) -> CGPDFPage {
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data)!
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 10, y: 10, width: 50, height: 50))
        let img = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
        ctx.draw(img, in: imageRect)
        if rotatedImage {
            ctx.saveGState()
            ctx.translateBy(x: 300, y: 100)
            ctx.rotate(by: .pi / 2)
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: 40, height: 20))
            ctx.restoreGState()
        }
        ctx.endPDFPage()
        ctx.closePDF()
        let doc = PDFDocument(data: data as Data)!
        return doc.page(at: 0)!.pageRef!
    }

    private func bounds(_ quad: [CGPoint]) -> CGRect {
        let xs = quad.map(\.x), ys = quad.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    func testFindsImagePlacementNotVectorFills() {
        let rect = CGRect(x: 100, y: 120, width: 80, height: 60)
        let quads = PDFImageFinder.imageQuads(in: makePDF(imageRect: rect))
        XCTAssertEqual(quads.count, 1, "one image, the vector rect is not reported")
        XCTAssertEqual(bounds(quads[0]).integral, rect)
        XCTAssertEqual(abs(PDFImageFinder.polygonArea(quads[0])), rect.width * rect.height, accuracy: 0.5)
    }

    func testRotatedImageKeepsItsFootprint() {
        let quads = PDFImageFinder.imageQuads(in: makePDF(imageRect: CGRect(x: 0, y: 0, width: 10, height: 10),
                                                          rotatedImage: true))
        XCTAssertEqual(quads.count, 2)
        // 40×20 drawn after a 90° rotation about (300,100) → footprint x 280…300, y 100…140.
        let rotated = quads.map(bounds).first { $0.width < $0.height }
        XCTAssertNotNil(rotated)
        XCTAssertEqual(rotated?.integral, CGRect(x: 280, y: 100, width: 20, height: 40))
    }

    func testPolygonAreaIsShoelace() {
        let square = [CGPoint(x: 0, y: 0), CGPoint(x: 2, y: 0), CGPoint(x: 2, y: 2), CGPoint(x: 0, y: 2)]
        XCTAssertEqual(PDFImageFinder.polygonArea(square), 4)
        XCTAssertEqual(PDFImageFinder.polygonArea(square.reversed()), -4)
        XCTAssertEqual(PDFImageFinder.polygonArea([CGPoint(x: 1, y: 1)]), 0)
    }
}
