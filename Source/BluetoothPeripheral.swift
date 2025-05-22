import SwiftUI
import CoreBluetooth



extension CBPeripheralManager
{
	#if os(tvOS)
	convenience init(delegate:CBPeripheralManagerDelegate,queue:dispatch_queue_t?)
	{
		self.init()
		self.delegate = delegate
	}
	#endif
}

public struct WriteMeta
{
	public var peer : UUID
	public var characteristic : CBUUID
	public var data : Data
}

public class BluetoothPeripheral : NSObject, CBPeripheralManagerDelegate, ObservableObject
{
	var peripheralManager : CBPeripheralManager!
	@Published public var state : CBManagerState = .unknown
	public var advertisingServices : [CBService]?	{	return isAdverting ? self.services : nil }
	//var isAdverting : Bool {	self.peripheralManager.isAdvertising	}
	@Published public var isAdverting : Bool = false
	@Published public var services = [CBMutableService]()
	@Published public var errors = [Error]()
	public var error : String?	{	errors.isEmpty ? nil : errors.map{ "\($0.localizedDescription)" }.joined(separator: "\n") }

	//	owner implemented services creator
	var createServicesCallback : () -> [CBMutableService]
	var onWriteCallback : (WriteMeta) -> Void
	var advertisedName : String
	
	@Published var peers = [UUID]()
	
	public init(advertisedName:String,createServices:@escaping()->[CBMutableService],onWrite:@escaping(WriteMeta)->Void) throws
	{
		self.advertisedName = advertisedName
		self.createServicesCallback = createServices
		self.onWriteCallback = onWrite
		super.init()
		self.peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
		
		#if os(tvOS)
		throw RuntimeError("TVOS cannot be a peripheral")
		#endif
	}

	
	func OnStateChanged(newState:CBManagerState)
	{
		print("Bluetooth state is \(newState)")
		/*
		DispatchQueue.main.async
		{
			@MainActor in
			self.state = newState
		}*/
		Task
		{
			@MainActor in
			self.state = newState
		}
	}
	
	public func OnError(_ error:Error)
	{
		Task
		{
			@MainActor in
			self.errors.append(error)
		}
	}
	
	//	reflect state of non-published peripheral
	func OnPeripheralStateChanged()
	{
		Task
		{
			@MainActor in
			self.isAdverting = self.peripheralManager.isAdvertising
		}
	}
	
	public func peripheralManagerDidStartAdvertising(_ peripheral:CBPeripheralManager,error:Error?)
	{
		OnPeripheralStateChanged()
		if let error
		{
			OnError(error)
			return
		}
	}

	
	//	device(us) state change	
	public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) 
	{
		//	trigger ui change
		OnStateChanged(newState: peripheral.state)
		
		switch peripheral.state 
		{
			case .unknown: 
				print("Bluetooth Device is UNKNOWN")
			case .unsupported:
				print("Bluetooth Device is UNSUPPORTED")
			case .unauthorized:
				print("Bluetooth Device is UNAUTHORIZED")
			case .resetting:
				print("Bluetooth Device is RESETTING")
			case .poweredOff:
				print("Bluetooth Device is POWERED OFF")
			case .poweredOn:
				print("Bluetooth Device is POWERED ON")
				InitPlayerListService()
			@unknown default:
				print("Unknown State")
		}
	}

	
	
	func InitPlayerListService()
	{
		let services = createServicesCallback()
		
		services.forEach{ self.services.append($0) }
		services.forEach{ self.peripheralManager.add($0) }
		
		let adverts : [String:Any] =
		[
			CBAdvertisementDataLocalNameKey : self.advertisedName,
			CBAdvertisementDataServiceUUIDsKey : services.map{ $0.uuid }
		]
		
		peripheralManager.startAdvertising(adverts)
	}
	
	public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) 
	{
		requests.forEach
		{
			writeRequest in
			let peerUid = writeRequest.central.identifier
			let data = writeRequest.value ?? Data()
			let write = WriteMeta(peer: peerUid, characteristic: writeRequest.characteristic.uuid, data: data )
			onWriteCallback(write)
		}
	}
	
	public func SetValue(service:CBUUID,characteristic:CBUUID,value:Data,peer:UUID?=nil) throws
	{
		guard let service = self.services.first(where:{ $0.uuid == service }) else
		{
			throw BluetoothError("No such service \(service)")
		}
		guard let char = service.GetMutableCharacteristic(characteristicUid: characteristic) else
		{
			throw BluetoothError("No such [mutable] characteristic \(characteristic) on service \(service)")
		}
		
		
		if let peer
		{
			guard let central = char.subscribedCentrals?.first(where: {$0.identifier == peer} ) else
			{
				throw BluetoothError("No subscribed peer \(peer)")
			}
			
			self.peripheralManager.updateValue(value, for: char, onSubscribedCentrals: [central])
		}
		else
		{
			//	broadcast
			self.peripheralManager.updateValue(value, for: char, onSubscribedCentrals: nil)
		}
	}
	
}
