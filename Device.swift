//
//  Device.swift
//  Aranet4MacApp
//
//  Created by Gael Dauchy on 24/10/2025.
//  Copyright © 2025 Aranet4Mac. All rights reserved.
//



//
//  Device.swift
//  Aranet4MacApp
//
//  Created by Gael Dauchy on 24/10/2025.
//

import Foundation
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif

/// Représente un appareil Aranet (ou compatible) découvert/associé.
public struct Device: Identifiable, Hashable, Codable {
    public let id: UUID           // ID interne app (stable pour la persistance)
    public let bleID: UUID        // Identifiant du périphérique BLE (CBPeripheral.identifier)
    public var name: String       // Nom visible (éditable par l'utilisateur)
    public var info: DeviceInfo?  // Informations lues (firmware, batterie, intervalle)

    public init(id: UUID = UUID(), bleID: UUID, name: String, info: DeviceInfo? = nil) {
        self.id = id
        self.bleID = bleID
        self.name = name
        self.info = info
    }

    #if canImport(CoreBluetooth)
    /// Helper pratique pour créer un `Device` depuis un `CBPeripheral`.
    public static func fromPeripheral(_ p: CBPeripheral, alias: String? = nil) -> Device {
        Device(bleID: p.identifier, name: alias ?? p.name ?? "Aranet4")
    }
    #endif
}

/// Métadonnées de l'appareil (optionnelles).
public struct DeviceInfo: Hashable, Codable {
    public var firmware: String?            // ex. "1.2.9"
    public var batteryPct: Int?             // 0...100
    public var measurementIntervalSec: Int? // ex. 60 (s)

    public init(firmware: String? = nil, batteryPct: Int? = nil, measurementIntervalSec: Int? = nil) {
        self.firmware = firmware
        self.batteryPct = batteryPct
        self.measurementIntervalSec = measurementIntervalSec
    }
}
