//
//  CDEBaselineConsolidatorTests.m
//  Ensembles Mac
//
//  Created by Drew McCormack on 04/12/13.
//  Copyright (c) 2013 Drew McCormack. All rights reserved.
//

#import <XCTest/XCTest.h>
#import "CDEEventStoreTestCase.h"
#import "CDEBaselineConsolidator.h"
#import "CDEStoreModificationEvent.h"
#import "CDEGlobalIdentifier.h"
#import "CDEEventRevision.h"
#import "CDERevisionSet.h"
#import "CDEPropertyChangeValue.h"
#import "CDERevision.h"

@interface CDEBaselineConsolidatorTests : CDEEventStoreTestCase

@end

@implementation CDEBaselineConsolidatorTests {
    NSManagedObjectContext *context;
    CDEBaselineConsolidator *consolidator;
}

- (void)setUp
{
    [super setUp];
    context = self.eventStore.managedObjectContext;
    consolidator = [[CDEBaselineConsolidator alloc] initWithEventStore:(id)self.eventStore];
}

- (void)testConsolidationNotNeededForNoBaselines
{
    XCTAssertFalse([consolidator baselineNeedsConsolidation], @"Should not need to consolidate empty store");
}

- (void)testConsolidationNotNeededForOneBaseline
{
    [context performBlockAndWait:^{
        CDEStoreModificationEvent *event = [NSEntityDescription insertNewObjectForEntityForName:@"CDEStoreModificationEvent" inManagedObjectContext:context];
        event.type = CDEStoreModificationEventTypeBaseline;
        [context save:NULL];
    }];
    XCTAssertFalse([consolidator baselineNeedsConsolidation], @"Should not need to consolidate one baseline");
}

- (void)testConsolidationIsNeededForTwoBaselines
{
    [context performBlockAndWait:^{
        CDEStoreModificationEvent *event = [NSEntityDescription insertNewObjectForEntityForName:@"CDEStoreModificationEvent" inManagedObjectContext:context];
        event.type = CDEStoreModificationEventTypeBaseline;
        
        event = [NSEntityDescription insertNewObjectForEntityForName:@"CDEStoreModificationEvent" inManagedObjectContext:context];
        event.type = CDEStoreModificationEventTypeBaseline;
        
        [context save:NULL];
    }];
    XCTAssertTrue([consolidator baselineNeedsConsolidation], @"Should need to consolidate two baselines");
}

- (void)testConsolidatingMultipleBaselinesKeepsMostRecent
{
    [self addBaselineEventsForStoreId:@"123" globalCounts:@[@(2), @(0), @(1)] revisions:@[@(2), @(0), @(1)]];
    
    [consolidator consolidateBaselineWithCompletion:^(NSError *error) {
        [context performBlock:^{
            NSArray *events = [self storeModEvents];
            XCTAssertEqual(events.count, (NSUInteger)1, @"Should only be one baseline left");
            
            CDEStoreModificationEvent *event = events.lastObject;
            XCTAssertEqual(event.globalCount, (int64_t)2, @"Wrong event was kept");
            
            dispatch_async(dispatch_get_main_queue(), ^{
                [self stopAsyncOp];
            });
        }];
    }];
    [self waitForAsyncOpToFinish];
}

- (void)testConsolidatingMultipleBaselinesWithMultipleStoresKeepsMostRecent
{
    [self addBaselineEventsForStoreId:@"123" globalCounts:@[@(2), @(0), @(1)] revisions:@[@(2), @(0), @(1)]];
    [self addBaselineEventsForStoreId:@"234" globalCounts:@[@(3)] revisions:@[@(0)]];

    [consolidator consolidateBaselineWithCompletion:^(NSError *error) {
        [context performBlock:^{
            NSArray *events = [self storeModEvents];
            XCTAssertEqual(events.count, (NSUInteger)1, @"Should only be one baseline left");
            
            CDEStoreModificationEvent *event = events.lastObject;
            XCTAssertEqual(event.globalCount, (int64_t)3, @"Wrong event was kept");
            XCTAssertEqualObjects(event.eventRevision.persistentStoreIdentifier, self.eventStore.persistentStoreIdentifier, @"Store id should be the event store id");

            dispatch_async(dispatch_get_main_queue(), ^{
                [self stopAsyncOp];
            });
        }];
    }];
    [self waitForAsyncOpToFinish];
}

- (void)testMergingConcurrentBaselinesKeepsMostRecentObjectChange
{
    CDEStoreModificationEvent *baseline0 = [[self addBaselineEventsForStoreId:@"123" globalCounts:@[@(10)] revisions:@[@(10)]] lastObject];
    CDEStoreModificationEvent *baseline1 = [[self addBaselineEventsForStoreId:@"234" globalCounts:@[@(20)] revisions:@[@(10)]] lastObject];
    [context performBlockAndWait:^{
        CDEGlobalIdentifier *globalId = [NSEntityDescription insertNewObjectForEntityForName:@"CDEGlobalIdentifier" inManagedObjectContext:context];
        globalId.globalIdentifier = @"123";
        globalId.nameOfEntity = @"Parent";

        CDEObjectChange *change1 = [self objectChangeForGlobalId:globalId valuesByKey:@{@"date":[NSDate dateWithTimeIntervalSince1970:10]}];
        change1.storeModificationEvent = baseline0;
        
        CDEObjectChange *change2 = [self objectChangeForGlobalId:globalId valuesByKey:@{@"date":[NSDate dateWithTimeIntervalSince1970:20]}];
        change2.storeModificationEvent = baseline1;
        
        NSError *error;
        XCTAssertTrue([context save:&error], @"Failed to save");
    }];
    
    
    [consolidator consolidateBaselineWithCompletion:^(NSError *error) {
        [context performBlock:^{
            NSArray *events = [self storeModEvents];
            CDEStoreModificationEvent *event = events.lastObject;
            
            NSSet *changes = event.objectChanges;
            XCTAssertEqual(changes.count, (NSUInteger)1, @"Wrong number of changes");
            
            CDEObjectChange *change = changes.anyObject;
            XCTAssertEqual(change.type, CDEObjectChangeTypeInsert, @"Wrong type");
            
            NSArray *values = change.propertyChangeValues;
            XCTAssertEqual(values.count, (NSUInteger)1, @"Wrong number of values");
            
            CDEPropertyChangeValue *value = values.lastObject;
            XCTAssertEqualObjects(value.value, [NSDate dateWithTimeIntervalSince1970:20], @"Wrong value");
            XCTAssertEqual(value.type, CDEPropertyChangeTypeAttribute, @"Wrong type");

            dispatch_async(dispatch_get_main_queue(), ^{
                [self stopAsyncOp];
            });
        }];
    }];
    [self waitForAsyncOpToFinish];
}

- (void)testMergingConcurrentBaselinesMergesPropertyValues
{
    CDEStoreModificationEvent *baseline0 = [[self addBaselineEventsForStoreId:@"123" globalCounts:@[@(10)] revisions:@[@(10)]] lastObject];
    CDEStoreModificationEvent *baseline1 = [[self addBaselineEventsForStoreId:@"234" globalCounts:@[@(20)] revisions:@[@(10)]] lastObject];
    [context performBlockAndWait:^{
        CDEGlobalIdentifier *globalId = [NSEntityDescription insertNewObjectForEntityForName:@"CDEGlobalIdentifier" inManagedObjectContext:context];
        globalId.globalIdentifier = @"123";
        globalId.nameOfEntity = @"Parent";
        
        NSDictionary *values = @{@"date":[NSDate dateWithTimeIntervalSince1970:10], @"strength":@5};
        CDEObjectChange *change1 = [self objectChangeForGlobalId:globalId valuesByKey:values];
        change1.storeModificationEvent = baseline0;
        
        values = @{@"date":[NSDate dateWithTimeIntervalSince1970:20]};
        CDEObjectChange *change2 = [self objectChangeForGlobalId:globalId valuesByKey:values];
        change2.storeModificationEvent = baseline1;
        
        NSError *error;
        XCTAssertTrue([context save:&error], @"Failed to save");
    }];
    
    
    [consolidator consolidateBaselineWithCompletion:^(NSError *error) {
        [context performBlock:^{
            NSArray *events = [self storeModEvents];
            CDEStoreModificationEvent *event = events.lastObject;
            
            NSSet *changes = event.objectChanges;
            XCTAssertEqual(changes .count, (NSUInteger)1, @"Wrong number of object changes");
            
            CDEObjectChange *change = changes.anyObject;
            NSArray *values = change.propertyChangeValues;
            XCTAssertEqual(values.count, (NSUInteger)2, @"Wrong number of values");
            
            NSArray *filteredValues = [values filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"propertyName = 'strength'"]];
            CDEPropertyChangeValue *value = filteredValues.lastObject;
            XCTAssertEqualObjects(value.value, @5, @"Wrong value");
            
            dispatch_async(dispatch_get_main_queue(), ^{
                [self stopAsyncOp];
            });
        }];
    }];
    [self waitForAsyncOpToFinish];
}

- (CDEObjectChange *)objectChangeForGlobalId:(CDEGlobalIdentifier *)globalId valuesByKey:(NSDictionary *)valuesByKey
{
    CDEObjectChange *change = [NSEntityDescription insertNewObjectForEntityForName:@"CDEObjectChange" inManagedObjectContext:context];
    change.type = CDEObjectChangeTypeInsert;
    change.globalIdentifier = globalId;
    change.nameOfEntity = globalId.nameOfEntity;
    
    NSMutableArray *values = [NSMutableArray array];
    for (NSString *key in valuesByKey) {
        CDEPropertyChangeValue *value = [[CDEPropertyChangeValue alloc] initWithType:CDEPropertyChangeTypeAttribute propertyName:@"date"];
        value.value = valuesByKey[key];
        [values addObject:value];
    }

    change.propertyChangeValues = values;
    
    return change;
}

- (NSArray *)addBaselineEventsForStoreId:(NSString *)storeId globalCounts:(NSArray *)globalCounts revisions:(NSArray *)revisions
{
    __block NSMutableArray *baselines = [NSMutableArray array];
    [context performBlockAndWait:^{
        for (NSUInteger i = 0; i < globalCounts.count; i++) {
            CDEStoreModificationEvent *event = [NSEntityDescription insertNewObjectForEntityForName:@"CDEStoreModificationEvent" inManagedObjectContext:context];
            event.type = CDEStoreModificationEventTypeBaseline;
            event.globalCount = [globalCounts[i] integerValue];
            event.timestamp = 10.0;
            
            CDEEventRevision *rev;
            rev = [CDEEventRevision makeEventRevisionForPersistentStoreIdentifier:storeId revisionNumber:[revisions[i] integerValue] inManagedObjectContext:context];
            event.eventRevision = rev;
            
            [baselines addObject:event];
        }
        
        [context save:NULL];
    }];
    
    return baselines;
}

- (void)waitForAsyncOpToFinish
{
    CFRunLoopRun();
}

- (void)stopAsyncOp
{
    CFRunLoopStop(CFRunLoopGetCurrent());
}

- (NSArray *)storeModEvents
{
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"CDEStoreModificationEvent"];
    return [context executeFetchRequest:fetch error:NULL];
}

@end