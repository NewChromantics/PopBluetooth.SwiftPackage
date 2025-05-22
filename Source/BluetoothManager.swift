import SwiftUI
import CoreBluetooth
import Combine


//	open to allow overriding
open class BluetoothPeripheralHandler : NSObject, CBPeripheralDelegate, Identifiable, ObservableObject
{
	public var peripheral: CBPeripheral
	public var id : UUID	{	peripheral.identifier	}
	var services : [CBService]	{	peripheral.services ?? []	}
	public var name : String	{	peripheral.name ?? "\(peripheral.identifier)"	}
	public var state : CBPeripheralState	{	peripheral.state	}
	@Published public var error : Error? = nil

	public required init(peripheral: CBPeripheral) 
	{
		self.peripheral = peripheral
		super.init()
		
		//	setup handling
		self.peripheral.delegate = self
	}
	
	//	reflect any non published changes
	public func OnPeripheralStateChanged()
	{
		DispatchQueue.main.async
		{
			@MainActor in
			self.objectWillChange.send()
		}
	}
	
	public func OnConnected() 
	{
		OnPeripheralStateChanged()
		
		//	start fetching services
		peripheral.discoverServices(nil)
	}
	
	
	public func OnError(_ error:Error)
	{
		DispatchQueue.main.async
		{
			@MainActor in
			print("Peripheral error \(error.localizedDescription)")
			self.error = error
		}
	}
	
	public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) 
	{
		if let error 
		{
			print("didDiscoverServices error \(error.localizedDescription)")
			self.error = error
			return
		}
		
		let services = peripheral.services ?? []
		let name = peripheral.name ?? "noname"
		print("did discover services x\(services.count) for \(name) (\(peripheral.state))")
		OnPeripheralStateChanged()
		
		//	start finding characteristics
		services.forEach
		{
			peripheral.discoverCharacteristics(nil, for: $0)
		}
		
	}
	
	
	//	catch any errors from notification update subscriptions
	public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) 
	{
		if let error 
		{
			print("didUpdateNotificationStateFor \(characteristic.uuid) error \(error.localizedDescription)")
			OnError(error)
			return
		}
		print("Characteristic Notification for \(characteristic.uuid) now \(characteristic.isNotifying)")
		
		do
		{
			//	gr: this is nil on first use
			guard let value = characteristic.value else 
			{
				throw BluetoothError("Missing characteristic \(characteristic.uuid) value")
			}
			
			//	dont need to distinguish between notify and value change?
			try OnCharacteristicValueChanged( value: value, characteristicUid: characteristic.uuid )
		}
		catch 
		{
			OnError(error)
		}
	}
	
	
	public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) 
	{
		do
		{
			if let error
			{
				print("didUpdateValueFor \(characteristic.uuid) error \(error.localizedDescription)")
				throw error
			}
			
			guard let value = characteristic.value else 
			{
				throw BluetoothError("Missing characteristic \(characteristic.uuid) value")
			}
			
			try OnCharacteristicValueChanged( value: value, characteristicUid: characteristic.uuid )
		}
		catch
		{
			OnError(error)
		}
	}
	
	public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) 
	{
		if let error 
		{
			print("didWriteValueFor \(characteristic.uuid) error \(error.localizedDescription)")
			OnError(error)
			return
		}
		
		print("Characteristic \(characteristic.uuid) wrote value")
	}
	
	public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) 
	{
		if let error 
		{
			print("didDiscoverCharacteristicsFor error \(error.localizedDescription)")
			OnError(error)
			return
		}
		
		let characteristics = service.characteristics ?? []
		print("did discover characteristics x\(characteristics.count) for \(name) (\(peripheral.state))")
		OnPeripheralStateChanged()
		
		do
		{
			try OnCharacteristicsFound(characteristics: characteristics,for:service)
		}
		catch
		{
			OnError(error)
		}
	}
	
	//	open to allow override
	open func OnCharacteristicsFound(characteristics:[CBCharacteristic],for service:CBService) throws
	{
		fatalError("Virtual function OnCharacteristicsFound not implemented")
	}
	
	//	open to allow override
	open func OnCharacteristicValueChanged(value: Data,characteristicUid:CBUUID) throws
	{
		fatalError("Virtual function OnCharacteristicValueChanged not implemented")
	}
	
}


struct BluetoothDevice : Identifiable, Hashable, Comparable
{
	static func < (lhs: BluetoothDevice, rhs: BluetoothDevice) -> Bool 
	{
		return lhs.name < rhs.name
	}
	
	static func ==(lhs: BluetoothDevice, rhs: BluetoothDevice) -> Bool
	{
		return lhs.id == rhs.id
	}
	
	func hash(into hasher: inout Hasher) 
	{
		hasher.combine(	id.hashValue)
	}
	
	var id : UUID	{	deviceUid	}
	var deviceUid : UUID
	var name : String
	var state : CBPeripheralState
	var services : [CBService]
	
	var debugColour : Color
	{
		let IsConnected = state == .connected
		let IsConnecting = state == .connecting

		if IsConnecting
		{
			return .yellow
		}
		if IsConnected
		{
			return .green
		}

		return .clear		
	}
}


extension CBManagerState : @retroactive CustomStringConvertible 
{
	public var description: String 
	{
		switch self
		{
			case CBManagerState.unknown:	return "unknown"
			case CBManagerState.resetting:	return "resetting"
			case CBManagerState.unsupported:	return "unsupported"
			case CBManagerState.unauthorized:	return "unauthorized"
			case CBManagerState.poweredOff:	return "poweredOff"
			case CBManagerState.poweredOn:	return "poweredOn"
			default:
				return String(describing: self)
		}
	}
}


extension CBPeripheralState : @retroactive CustomStringConvertible 
{
	public var description: String 
	{
		switch self
		{
			case .connected:	return "connected"
			case .connecting:	return "connecting"
			case .disconnected:	return "disconnected"
			case .disconnecting:	return "disconnecting"
			default:
				return String(describing: self)
		}
	}
}

public class BluetoothManager : NSObject, CBCentralManagerDelegate, ObservableObject
{
	var centralManager : CBCentralManager!
	var devices : [BluetoothDevice]	{	Array(deviceStates).sorted()	}
	@Published var lastState : CBManagerState = .unknown
	@Published var isScanning : Bool = false
	@Published var deviceStates = Set<BluetoothDevice>()
	var showNoNameDevices = false
	
	//	return a handler if you want this device to be connected
	var onPeripheralFoundCallback : (CBPeripheral)->BluetoothPeripheralHandler?
	var requiredServices : [CBUUID]?
	
	//	need to keep a strong reference to peripherals we're connecting to
	//	gr: is now a callback interface
	var connectingPeripherals = [UUID:BluetoothPeripheralHandler]()
	
	public init(onPeripheralFound:@escaping(CBPeripheral)->BluetoothPeripheralHandler?=BluetoothManager.DefaultHandler,requireServices:[CBUUID]?=nil)
	{
		self.requiredServices = requireServices
		self.onPeripheralFoundCallback = onPeripheralFound
		super.init()
		centralManager = CBCentralManager(delegate: self, queue: nil)
	}
	
	public static func DefaultHandler(_:CBPeripheral) -> BluetoothPeripheralHandler?
	{
		return nil
	}
	
	
	func updateDeviceState(_ peripheral:CBPeripheral)
	{
		/*
		if !self.showNoNameDevices && peripheral.name == nil
		{
			return
		}*/
		
		let name = peripheral.name ?? "\(peripheral.identifier)"
		let services = peripheral.services ?? []
		let device = BluetoothDevice(deviceUid: peripheral.identifier, name: name, state: peripheral.state, services: services)
		
		DispatchQueue.main.async
		{
			@MainActor in
			self.deviceStates.update(with: device)
		}
	}
	
	public func centralManager(_ central: CBCentralManager, 
								didDiscover peripheral: CBPeripheral, 
								advertisementData: [String : Any], 
								rssi RSSI: NSNumber)
	{
		let name = peripheral.name ?? "\(peripheral.identifier)"
		
		//	see if we want to make a handler for this device
		if connectingPeripherals[peripheral.identifier] == nil
		{
			if let newHandler = self.onPeripheralFoundCallback(peripheral)
			{
				//	we got a new handler back, which means parent wants to connect to this device
				connectingPeripherals[peripheral.identifier] = newHandler
				central.connect(peripheral)
			}
		}
	
		//print("Updating \(name) (\(peripheral.state))")
		updateDeviceState(peripheral)
	}
	

	public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) 
	{
		updateDeviceState(peripheral)

		guard let handler = connectingPeripherals[peripheral.identifier] else
		{
			print("Connected to peripheral without handler; \(peripheral.name) (\(peripheral.state))")
			return
		}
			
		print("Connected to peripheral \(peripheral.name) (\(peripheral.state))")
		handler.OnConnected()
	}	
	
	public func centralManagerDidUpdateState(_ central: CBCentralManager) 
	{
		lastState = central.state
		isScanning = central.isScanning
		
		if central.state == .poweredOn
		{
			central.scanForPeripherals(withServices:requiredServices)
		}
	}
}
