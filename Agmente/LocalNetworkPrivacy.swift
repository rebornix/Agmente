//
//  LocalNetworkPrivacy.swift
//  Agmente
//
//  Utility to check local network access permission status.
//

import Foundation
import Network
import UIKit

class LocalNetworkPrivacy: NSObject {
    private let service: NetService
    private var completion: ((Bool) -> Void)?
    private var timer: Timer?
    private var publishing = false

    override init() {
        service = NetService(domain: "local.", type: "_lnp._tcp.", name: "LocalNetworkPrivacy", port: 1100)
        super.init()
    }

    /// Checks if local network access has been granted.
    /// - Parameter completion: Called with `true` if access is granted, `false` otherwise.
    func checkAccessState(completion: @escaping (Bool) -> Void) {
        self.completion = completion

        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }

            guard UIApplication.shared.applicationState == .active else {
                return
            }

            if self.publishing {
                self.timer?.invalidate()
                self.completion?(false)
            } else {
                self.publishing = true
                self.service.delegate = self
                self.service.publish()
            }
        }
    }

    deinit {
        service.stop()
        timer?.invalidate()
    }
}

extension LocalNetworkPrivacy: NetServiceDelegate {
    func netServiceDidPublish(_ sender: NetService) {
        timer?.invalidate()
        completion?(true)
    }
}