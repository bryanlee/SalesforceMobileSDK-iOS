/*
 Copyright (c) 2015-present, salesforce.com, inc. All rights reserved.
 
 Redistribution and use of this software in source and binary forms, with or without modification,
 are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright notice, this list of conditions
 and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright notice, this list of
 conditions and the following disclaimer in the documentation and/or other materials provided
 with the distribution.
 * Neither the name of salesforce.com, inc. nor the names of its contributors may be used to
 endorse or promote products derived from this software without specific prior written
 permission of salesforce.com, inc.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR
 IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
 FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY
 WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "SFSoqlSyncDownTarget.h"
#import "SFSmartSyncSyncManager.h"
#import "SFSmartSyncConstants.h"
#import "SFSmartSyncObjectUtils.h"
#import "SFSmartSyncNetworkUtils.h"

static NSString * const kSFSoqlSyncTargetQuery = @"query";

@interface SFSoqlSyncDownTarget ()

@property (nonatomic, strong, readwrite) NSString* nextRecordsUrl;

@end

@implementation SFSoqlSyncDownTarget

- (instancetype)initWithDict:(NSDictionary *)dict {
    self = [super initWithDict:dict];
    if (self) {
        self.queryType = SFSyncDownTargetQueryTypeSoql;
        self.query = dict[kSFSoqlSyncTargetQuery];
        [self addSpecialFieldsIfRequired];
    }
    return self;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.queryType = SFSyncDownTargetQueryTypeSoql;
        [self addSpecialFieldsIfRequired];
    }
    return self;
}

- (void) addSpecialFieldsIfRequired {

    // Inserts the mandatory 'LastModifiedDate' field if it doesn't exist.
    if ([self.query rangeOfString:self.modificationDateFieldName].location == NSNotFound) {
        self.query = [SFSoqlSyncDownTarget appendToFirstOccurence:self.query pattern:@"select " stringToAppend:[@[self.modificationDateFieldName, @", "] componentsJoinedByString:@""]];
    }

    // Inserts the mandatory 'Id' field if it doesn't exist.
    if ([self.query rangeOfString:self.idFieldName].location == NSNotFound) {
        self.query = [SFSoqlSyncDownTarget appendToFirstOccurence:self.query pattern:@"select " stringToAppend:[@[self.idFieldName, @", "] componentsJoinedByString:@""]];
    }
}

#pragma mark - Factory methods

+ (SFSoqlSyncDownTarget*) newSyncTarget:(NSString*)query {
    SFSoqlSyncDownTarget* syncTarget = [[SFSoqlSyncDownTarget alloc] init];
    syncTarget.queryType = SFSyncDownTargetQueryTypeSoql;
    syncTarget.query = query;
    [syncTarget addSpecialFieldsIfRequired];
    return syncTarget;
}

#pragma mark - From/to dictionary

- (NSMutableDictionary*) asDict {
    NSMutableDictionary *dict = [super asDict];
    dict[kSFSoqlSyncTargetQuery] = self.query;
    return dict;
}

# pragma mark - Data fetching

- (void) startFetch:(SFSmartSyncSyncManager*)syncManager
        maxTimeStamp:(long long)maxTimeStamp
        errorBlock:(SFSyncDownTargetFetchErrorBlock)errorBlock
        completeBlock:(SFSyncDownTargetFetchCompleteBlock)completeBlock
{
    [self startFetch:syncManager
          queryToRun:[self getQueryToRun:maxTimeStamp]
          errorBlock:errorBlock
       completeBlock:completeBlock];
}

- (void) startFetch:(SFSmartSyncSyncManager*)syncManager
        queryToRun:(NSString *)queryToRun
        errorBlock:(SFSyncDownTargetFetchErrorBlock)errorBlock
      completeBlock:(SFSyncDownTargetFetchCompleteBlock)completeBlock {
    __weak typeof(self) weakSelf = self;
    
    SFRestRequest* request = [[SFRestAPI sharedInstance] requestForQuery:queryToRun];
    [SFSmartSyncNetworkUtils sendRequestWithSmartSyncUserAgent:request failBlock:errorBlock completeBlock:^(NSDictionary *d) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        strongSelf.totalSize = [d[kResponseTotalSize] integerValue];
        strongSelf.nextRecordsUrl = d[kResponseNextRecordsUrl];
        completeBlock(d[kResponseRecords]);
    }];
}

- (void) continueFetch:(SFSmartSyncSyncManager *)syncManager
            errorBlock:(SFSyncDownTargetFetchErrorBlock)errorBlock
         completeBlock:(SFSyncDownTargetFetchCompleteBlock)completeBlock {
    if (self.nextRecordsUrl) {
        __weak typeof(self) weakSelf = self;
        SFRestRequest* request = [SFRestRequest requestWithMethod:SFRestMethodGET path:self.nextRecordsUrl queryParams:nil];
        [SFSmartSyncNetworkUtils sendRequestWithSmartSyncUserAgent:request failBlock:errorBlock completeBlock:^(NSDictionary *d) {
            weakSelf.nextRecordsUrl = d[kResponseNextRecordsUrl];
            completeBlock(d[kResponseRecords]);
        }];
    } else {
        completeBlock(nil);
    }
}

- (void)getRemoteIds:(SFSmartSyncSyncManager *)syncManager
            localIds:(NSArray *)localIds
          errorBlock:(SFSyncDownTargetFetchErrorBlock)errorBlock
       completeBlock:(SFSyncDownTargetFetchCompleteBlock)completeBlock {
    if (localIds == nil) {
        completeBlock(nil);
        return;
    }
    NSMutableString* soql = [[NSMutableString alloc] initWithString:@"SELECT "];
    [soql appendString:self.idFieldName];
    NSRegularExpression* regexp = [NSRegularExpression regularExpressionWithPattern:@" from " options:NSRegularExpressionCaseInsensitive error:nil];
    NSRange rangeFirst = [regexp rangeOfFirstMatchInString:self.query options:0 range:NSMakeRange(0, self.query.length)];
    NSString* fromClause = [self.query substringFromIndex:rangeFirst.location];
    [soql appendString:fromClause];
    __block NSUInteger countFetched = 0;
    __block NSMutableArray* remoteIds = [[NSMutableArray alloc] init];
    __block SFSyncDownTargetFetchCompleteBlock fetchBlockRecurse = ^(NSArray *records) {};
    SFSyncDownTargetFetchCompleteBlock fetchBlock = ^(NSArray* records) {
        // NB with the recursive block, using weakSelf doesn't work (it goes to nil)
        //    are we leaking memory?
        if (countFetched == 0) {
            if (self.totalSize == 0) {
                completeBlock(nil);
                return;
            }
        }
        countFetched += [records count];
        for (NSDictionary * record in records) {
            [remoteIds addObject:record[self.idFieldName]];
        }
        if (countFetched < self.totalSize) {
            [self continueFetch:syncManager errorBlock:errorBlock completeBlock:fetchBlockRecurse];
        } else {
            completeBlock(remoteIds);
        }
    };
    fetchBlockRecurse = fetchBlock;
    [self startFetch:syncManager queryToRun:soql errorBlock:errorBlock completeBlock:fetchBlock];
}

#pragma mark - Utility methods

- (NSString*) getQueryToRun {
    return [self getQueryToRun:0];
}

- (NSString*) getQueryToRun:(long long)maxTimeStamp {
    NSString* queryToRun = self.query;
    if (maxTimeStamp > 0) {
        queryToRun = [SFSoqlSyncDownTarget addFilterForReSync:self.query modDateFieldName:self.modificationDateFieldName maxTimeStamp:maxTimeStamp];
    }
    return queryToRun;
}

+ (NSString*) addFilterForReSync:(NSString*)query modDateFieldName:(NSString *)modDateFieldName maxTimeStamp:(long long)maxTimeStamp {
    NSString* queryToRun = query;
    if (maxTimeStamp > 0) {
        NSString* maxTimeStampStr = [SFSmartSyncObjectUtils getIsoStringFromMillis:maxTimeStamp];
        NSString* extraPredicate =  [@[modDateFieldName, @">", maxTimeStampStr] componentsJoinedByString:@" "];
        if ([[query lowercaseString] rangeOfString:@" where "].location != NSNotFound) {
            queryToRun = [SFSoqlSyncDownTarget appendToFirstOccurence:query pattern:@" where " stringToAppend:[@[extraPredicate, @" and "] componentsJoinedByString:@""]];
        } else {
            queryToRun = [SFSoqlSyncDownTarget appendToFirstOccurence:query pattern:@" from[ ]+[^ ]*" stringToAppend:[@[@" where ", extraPredicate] componentsJoinedByString:@""]];
        }
    }
    return queryToRun;
}

+ (NSString*) appendToFirstOccurence:(NSString*)str pattern:(NSString*)pattern stringToAppend:(NSString*)stringToAppend {
    NSRegularExpression* regexp = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
    NSRange rangeFirst = [regexp rangeOfFirstMatchInString:str options:0 range:NSMakeRange(0, [str length])];
    NSString* firstMatch = [str substringWithRange:rangeFirst];
    NSString* modifiedStr = [str stringByReplacingCharactersInRange:rangeFirst withString:[@[firstMatch, stringToAppend] componentsJoinedByString:@""]];
    return modifiedStr;
}

@end
