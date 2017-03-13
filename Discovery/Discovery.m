//
//  Discovery.m
//  DiscoveryExample
//
//  Created by Ömer Faruk Gül on 08/02/15.
//  Copyright (c) 2015 Ömer Faruk Gül. All rights reserved.
//

#import "Discovery.h"

#define PERIPHERAL_RESTORE_IDENTIFIER @"866A5887-32A9-421C-9DE2-C0231B09A699"
#define CENTRAL_RESTORE_IDENTIFIER @"46355B1F-DCBF-4EAF-A4D1-19795377A7AA"

@interface Discovery()
@property (nonatomic, copy) void (^usersBlock)(NSArray *users, BOOL usersChanged);
@property (strong, nonatomic) NSTimer *timer;
@property (nonatomic, getter=isInBackgroundMode) BOOL inBackgroundMode;
@end

static double bgStartTime = 0.0f;

@implementation Discovery

- (instancetype)initWithUUID:(CBUUID *)uuid {
    self = [super init];
    if(self) {
        _uuid = uuid;
        
        _inBackgroundMode = NO;
        
        _userTimeoutInterval = 3;
        _updateInterval = 2;
        
        // listen for UIApplicationDidEnterBackgroundNotification
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(appDidEnterBackground:)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
        
        // listen for UIApplicationDidEnterBackgroundNotification
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(appWillEnterForeground:)
                                                     name:UIApplicationWillEnterForegroundNotification
                                                   object:nil];
        
        
        // we will hold the detected users here
        _usersMap = [NSMutableDictionary dictionary];
        
        // start the central and peripheral managers
        _queue = dispatch_queue_create("com.omerfarukgul.discovery", DISPATCH_QUEUE_SERIAL);
        
        _shouldAdvertise = NO;
        _shouldDiscover = NO;
        
        
    }
    
    return self;
}

- (void)startAdvertisingWithUsername:(NSString *)username
{
    _username = username;
    self.shouldAdvertise = YES;
}

- (void)stopAdvertising
{
    self.shouldAdvertise = NO;
}

- (void)startDiscovering:(void (^)(NSArray *users, BOOL usersChanged))usersBlock
{
    self.usersBlock = usersBlock;
    self.shouldDiscover = YES;
}

- (void)stopDiscovering
{
    self.shouldDiscover = NO;
}

-(void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillEnterForegroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
    
    NSLog(@"Discovery deallocated.");
}

-(void)setShouldAdvertise:(BOOL)shouldAdvertise {
    if(_shouldAdvertise == shouldAdvertise)
        return;
    
    _shouldAdvertise = shouldAdvertise;
    
    if(shouldAdvertise) {
        if (!self.peripheralManager)
            self.peripheralManager =
            [[CBPeripheralManager alloc]
             initWithDelegate:self
             queue:self.queue
             options:@{
                       CBPeripheralManagerOptionRestoreIdentifierKey: PERIPHERAL_RESTORE_IDENTIFIER
                       }];
    } else {
        if (self.peripheralManager) {
            [self.peripheralManager stopAdvertising];
            self.peripheralManager.delegate = nil;
            self.peripheralManager = nil;
        }
    }
}

-(void)setShouldDiscover:(BOOL)shouldDiscover {
    if(_shouldDiscover == shouldDiscover)
        return;
    
    _shouldDiscover = shouldDiscover;
    
    if(shouldDiscover) {
        if (!self.centralManager)
            self.centralManager =
            [[CBCentralManager alloc]
             initWithDelegate:self
             queue:self.queue
             options:@{
                       CBCentralManagerOptionRestoreIdentifierKey: CENTRAL_RESTORE_IDENTIFIER
                       }];
        if (!self.timer)
            [self startTimer];
    } else {
        if (self.centralManager) {
            [self.centralManager stopScan];
            self.centralManager.delegate = nil;
            self.centralManager = nil;
        }
        if (self.timer)
            [self stopTimer];
    }
}

- (void)startTimer {
    self.timer = [NSTimer scheduledTimerWithTimeInterval:self.updateInterval target:self
                                                selector:@selector(checkList) userInfo:nil repeats:YES];
}

- (void)stopTimer {
    [self.timer invalidate];
    self.timer = nil;
}

- (void)setUpdateInterval:(NSTimeInterval)updateInterval {
    _updateInterval = updateInterval;
    
    // restart the timers
    [self stopTimer];
    [self startTimer];
}

- (void)appDidEnterBackground:(NSNotification *)notification {
    self.inBackgroundMode = YES;
    bgStartTime = CFAbsoluteTimeGetCurrent();
    [self stopTimer];
}

- (void)appWillEnterForeground:(NSNotification *)notification {
    self.inBackgroundMode = NO;
    [self startTimer];
}

- (void)startAdvertising {
    
    NSDictionary *advertisingData = @{CBAdvertisementDataLocalNameKey:self.username,
                                      CBAdvertisementDataServiceUUIDsKey:@[self.uuid]
                                      };
    
    // create our characteristics
    CBMutableCharacteristic *characteristic =
    [[CBMutableCharacteristic alloc] initWithType:self.uuid
                                       properties:CBCharacteristicPropertyRead
                                            value:[self.username dataUsingEncoding:NSUTF8StringEncoding]
                                      permissions:CBAttributePermissionsReadable];
    
    // create the service with the characteristics
    CBMutableService *service = [[CBMutableService alloc] initWithType:self.uuid primary:YES];
    service.characteristics = @[characteristic];
    [self.peripheralManager addService:service];
    
    [self.peripheralManager startAdvertising:advertisingData];
}

- (void)startDetecting {
    
    NSDictionary *scanOptions = @{CBCentralManagerScanOptionAllowDuplicatesKey:@(YES)};
    NSArray *services = @[self.uuid];
    
    // we only listen to the service that belongs to our uuid
    // this is important for performance and battery consumption
    [self.centralManager scanForPeripheralsWithServices:services options:scanOptions];
}

- (void)peripheralManagerDidStartAdvertising:(CBPeripheralManager *)peripheral error:(NSError *)error {
    NSLog(@"Peripheral manager did start advertising (error %@)", error);
}

- (void)peripheralManagerDidUpdateState:(CBPeripheralManager *)peripheral {
    if(peripheral.state == CBManagerStatePoweredOn) {
        [self startAdvertising];
    }
    NSLog(@"Peripheral manager state: %ld", (long)peripheral.state);
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central
{
    if (central.state == CBManagerStatePoweredOn) {
        [self startDetecting];
    }
    NSLog(@"Central manager state: %ld", (long)central.state);
}

- (void)updateList {
    [self updateList:YES];
}

- (void)updateList:(BOOL)usersChanged {
    
    NSMutableArray *users;
    
    @synchronized(self.usersMap) {
        users = [[[self usersMap] allValues] mutableCopy];
    }
    
    // remove unidentified users
    NSMutableArray *discardedItems = [NSMutableArray array];
    for (BLEUser *user in users) {
        if (!user.isIdentified)
            [discardedItems addObject:user];
    }
    [users removeObjectsInArray:discardedItems];
    
    // we sort the list according to "proximity".
    // so the client will receive ordered users according to the proximity.
    [users sortUsingDescriptors: [NSArray arrayWithObjects: [NSSortDescriptor sortDescriptorWithKey:@"proximity"
                                                                                          ascending:NO], nil]];
    
    if(self.usersBlock) {
        self.usersBlock([users mutableCopy], usersChanged);
    }
}

- (void)checkList {
    
    double currentTime = [[NSDate date] timeIntervalSince1970];
    
    NSMutableArray *discardedKeys = [NSMutableArray array];
    
    for (NSString* key in self.usersMap) {
        BLEUser *bleUser = [self.usersMap objectForKey:key];
        
        NSTimeInterval diff = currentTime - bleUser.updateTime;
        
        // We remove the user if we haven't seen him for the userTimeInterval amount of seconds.
        // You can simply set the userTimeInterval variable anything you want.
        if(diff > self.userTimeoutInterval) {
            [discardedKeys addObject:key];
        }
    }
    
    // update the list if we removed a user.
    if(discardedKeys.count > 0) {
        [self.usersMap removeObjectsForKeys:discardedKeys];
        [self updateList];
    }
    else {
        // simply update the list, because the order of the users may have changed.
        [self updateList:NO];
    }
}

- (BLEUser *)userWithPeripheralId:(NSString *)peripheralId {
    return [self.usersMap valueForKey:peripheralId];
}

#pragma mark - CBCentralManagerDelegate

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary *)advertisementData
                  RSSI:(NSNumber *)RSSI
{
    NSString *username = advertisementData[CBAdvertisementDataLocalNameKey];
    NSLog(@"Discovered: %@ %@ at %@ -- %@", peripheral.name, peripheral.identifier, RSSI, username);
    
    if(self.isInBackgroundMode) {
        double bgTime = (CFAbsoluteTimeGetCurrent() - bgStartTime);
        [[NSUserDefaults standardUserDefaults] setDouble:bgTime forKey:@"bgTime"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        NSLog(@"Bgtime : %f", bgTime);
    }
    
    BLEUser *bleUser = [self userWithPeripheralId:peripheral.identifier.UUIDString];
    if(bleUser == nil) {
        //NSLog(@"Adding ble user: %@", name);
        bleUser = [[BLEUser alloc] initWithPerpipheral:peripheral];
        bleUser.username = nil;
        
        bleUser.identified = NO;
        bleUser.peripheral.delegate = self;
        
        [self.usersMap setObject:bleUser forKey:bleUser.peripheralId];
    }
    
    if(!bleUser.isIdentified) {
        // We check if we can get the username from the advertisement data,
        // in case the advertising peer application is working at foreground
        // if we get the name from advertisement we don't have to establish a peripheral connection
        if (username != (id)[NSNull null] && username.length > 0 ) {
            bleUser.username = username;
            bleUser.identified = YES;
            
            // we update our list for callback block
            [self updateList];
        }
        if(peripheral.state == CBPeripheralStateDisconnected) {
            [self.centralManager
             connectPeripheral:peripheral
             options:@{
                       CBConnectPeripheralOptionNotifyOnConnectionKey: [NSNumber numberWithBool:YES],
                       CBConnectPeripheralOptionNotifyOnDisconnectionKey: [NSNumber numberWithBool:YES]}];
        }
    }
    
    // update the rss and update time
    bleUser.rssi = [RSSI floatValue];
    bleUser.updateTime = [[NSDate date] timeIntervalSince1970];
}

- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error
{
    NSLog(@"Peripheral connection failure: %@. (%@)", peripheral, [error localizedDescription]);
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral
{
    BLEUser *user = [self userWithPeripheralId:peripheral.identifier.UUIDString];
    NSLog(@"Peripheral Connected: %@", user);
    
    // Search only for services that match our UUID
    // the connection does not guarantee that we will discover the services.
    // if the device is too far away, it may not be possible to discover the service we want.
    [peripheral discoverServices:@[self.uuid]];
}

- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error
{
    NSLog(@"Peripheral disconnected, requesting reconnect...");
    [central connectPeripheral:peripheral options:nil];
//    BLEUser *user = [self userWithPeripheralId:peripheral.identifier.UUIDString];
//    NSLog(@"Peripheral Disconnected: %@", user);
}

- (void)centralManager:(CBCentralManager *)central willRestoreState:(NSDictionary<NSString *,id> *)dict {
    NSLog(@"Central manager will restore state: %@", dict);
}

#pragma mark - CBPeripheralDelegate

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error
{
    NSLog(@"Peripheral did discover services");
    // loop the services
    // since we are looking forn only one service, services array probably contains only one or zero item
    for (CBService *service in peripheral.services) {
        [peripheral discoverCharacteristics:nil forService:service];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error
{
    BLEUser *user = [self userWithPeripheralId:peripheral.identifier.UUIDString];
    NSLog(@"Did discover characteristics of: %@ - %@", user.username, service.characteristics);
    
    if (!error) {
        // loop through to find our characteristic
        for (CBCharacteristic *characteristic in service.characteristics) {
            if ([characteristic.UUID isEqual:self.uuid]) {
                [peripheral readValueForCharacteristic:characteristic];
                [peripheral setNotifyValue:YES forCharacteristic:characteristic];
            }
        }
    }
    
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error
{
    NSString *valueStr = [[NSString alloc] initWithData:characteristic.value encoding:NSUTF8StringEncoding];
    NSLog(@"CBCharacteristic updated value: %@", valueStr);
    
    // if the value is not nil, we found our username!
    if(valueStr != nil) {
        BLEUser *user = [self userWithPeripheralId:peripheral.identifier.UUIDString];
        user.username = valueStr;
        user.identified = YES;
        
        [self updateList];
        
//        // cancel the subscription to our characteristic
//        [peripheral setNotifyValue:NO forCharacteristic:characteristic];
//        
//        // and disconnect from the peripehral
//        [self.centralManager cancelPeripheralConnection:peripheral];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error
{
    NSLog(@"Characteristic Update Notification: %@", error);
}

- (void)peripheralDidUpdateName:(CBPeripheral *)peripheral {
    NSLog(@"Peripheral has new name");
}

#pragma mark - CBPeripheralManagerDelegate

- (void)peripheralManager:(CBPeripheralManager *)peripheral willRestoreState:(NSDictionary<NSString *,id> *)dict {
    NSLog(@"Peripheral manager will restore state: %@", dict);
}

@end
