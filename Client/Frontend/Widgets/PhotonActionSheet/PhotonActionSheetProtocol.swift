/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared
import Storage

protocol PhotonActionSheetProtocol {
    var tabManager: TabManager { get }
    var profile: Profile { get }
}

private let log = Logger.browserLogger

extension PhotonActionSheetProtocol {
    typealias PresentableVC = UIViewController & UIPopoverPresentationControllerDelegate
    typealias MenuAction = () -> Void

    func presentSheetWith(title: String? = nil, actions: [[PhotonActionSheetItem]], on viewController: PresentableVC, from view: UIView, closeButtonTitle: String = Strings.CloseButtonTitle, suppressPopover: Bool = false) {
        let style: UIModalPresentationStyle = (UIDevice.current.userInterfaceIdiom == .pad && !suppressPopover) ? .popover : .overCurrentContext
        let sheet = PhotonActionSheet(title: title, actions: actions, closeButtonTitle: closeButtonTitle, style: style)
        sheet.modalPresentationStyle = style
        sheet.photonTransitionDelegate = PhotonActionSheetAnimator()

        if let popoverVC = sheet.popoverPresentationController, sheet.modalPresentationStyle == .popover {
            popoverVC.delegate = viewController
            popoverVC.sourceView = view
            popoverVC.sourceRect = CGRect(x: view.frame.width/2, y: view.frame.size.height * 0.75, width: 1, height: 1)
            popoverVC.permittedArrowDirections = .up
        }
        viewController.present(sheet, animated: true, completion: nil)
    }

    typealias PageOptionsVC = SettingsDelegate & PresentingModalViewControllerDelegate & UIViewController

    func fetchBookmarkStatus(for url: String) -> Bool {
        return profile.db.getBookmarksWithURL(url: url).count > 0
    }

    func fetchPinnedTopSiteStatus(for url: String) -> Bool {
        return self.profile.db.isPinnedTopSite(url)
    }

    func getLongPressLocationBarActions(with urlBar: URLBarView) -> [PhotonActionSheetItem] {
        let pasteGoAction = PhotonActionSheetItem(title: Strings.PasteAndGoTitle, iconString: "menu-PasteAndGo") { _, _ in
            if let pasteboardContents = UIPasteboard.general.string {
                urlBar.delegate?.urlBar(urlBar, didSubmitText: pasteboardContents)
            }
        }
        let pasteAction = PhotonActionSheetItem(title: Strings.PasteTitle, iconString: "menu-Paste") { _, _ in
            if let pasteboardContents = UIPasteboard.general.string {
                urlBar.enterOverlayMode(pasteboardContents, pasted: true, search: true)
            }
        }
        let copyAddressAction = PhotonActionSheetItem(title: Strings.CopyAddressTitle, iconString: "menu-Copy-Link") { _, _ in
            if let url = self.tabManager.selectedTab?.canonicalURL?.displayURL ?? urlBar.currentURL {
                UIPasteboard.general.url = url
            }
        }
        if UIPasteboard.general.string != nil {
            return [pasteGoAction, pasteAction, copyAddressAction]
        } else {
            return [copyAddressAction]
        }
    }
}
