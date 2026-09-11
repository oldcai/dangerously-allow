import XCTest
@testable import DangerouslyAllowCore

final class NativeDialogSurfaceTests: XCTestCase {
    func testNativeDialogRoles() {
        XCTAssertTrue(NativeDialogSurface.isDialog(role: "AXSheet", subrole: ""))
        XCTAssertTrue(NativeDialogSurface.isDialog(role: "AXDialog", subrole: ""))
        for subrole in ["AXDialog", "AXApplicationDialog", "AXApplicationAlertDialog"] {
            XCTAssertTrue(NativeDialogSurface.isDialog(role: "AXGroup", subrole: subrole))
        }
        XCTAssertFalse(NativeDialogSurface.isDialog(role: "AXGroup", subrole: ""))
        XCTAssertFalse(NativeDialogSurface.isDialog(role: "AXWindow", subrole: "AXStandardWindow"))
    }

    func testWebDocumentsAreNotSearched() {
        XCTAssertFalse(NativeDialogSurface.shouldDescend(role: "AXWebArea"))
        XCTAssertTrue(NativeDialogSurface.shouldDescend(role: "AXGroup"))
    }
}
