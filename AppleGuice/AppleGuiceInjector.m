//Copyright 2013 Tomer Shiri appleguice@shiri.info
//
//Licensed under the Apache License, Version 2.0 (the "License");
//you may not use this file except in compliance with the License.
//You may obtain a copy of the License at
//
//http://www.apache.org/licenses/LICENSE-2.0
//
//Unless required by applicable law or agreed to in writing, software
//distributed under the License is distributed on an "AS IS" BASIS,
//WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//See the License for the specific language governing permissions and
//limitations under the License.

#import "AppleGuiceInjector.h"
#import "AppleGuiceProtocolLocatorProtocol.h"
#import "AppleGuiceSingletonRepository.h"
#import "AppleGuiceSettingsProviderProtocol.h"
#import <objc/runtime.h>
#import "AppleGuiceInvocationProxy.h"

@implementation AppleGuiceInjector {
    id<AppleGuiceProtocolLocatorProtocol> _ioc_protocolLocator;
    id<AppleGuiceSingletonRepositoryProtocol> _ioc_singletonRepository;
    id<AppleGuiceSettingsProviderProtocol> _ioc_settingsProvider;
}

@synthesize protocolLocator = _ioc_protocolLocator, settingsProvider = _ioc_settingsProvider, singletonRepository = _ioc_singletonRepository;


-(NSArray*) allInstancesForProtocol:(Protocol*) protocol {
    NSArray* classesForProtocol = [self.protocolLocator getAllClassesByProtocolType:protocol];
    if (!classesForProtocol || [classesForProtocol count] == 0) return nil;
    NSMutableArray* instances = [[NSMutableArray alloc] initWithCapacity:[classesForProtocol count]];
    
    for (Class clazz in classesForProtocol) {
        id instance = [self instanceForClass:clazz];
        
        if (!instance) continue;
        
        [instances addObject:instance];
    }
    return [instances autorelease];
}

-(id<NSObject>) instanceForProtocol:(Protocol*) protocol {
    NSArray* classesForProtocol = [self.protocolLocator getAllClassesByProtocolType:protocol];
    if (!classesForProtocol || [classesForProtocol count] == 0) return nil;
    Class clazz = [classesForProtocol objectAtIndex:0];
    return [self instanceForClass:clazz];
}

-(id<NSObject>) instanceForClass:(Class) clazz {
    id classInstance;
    
    if ([self _shouldInjectSingletons]) {
        classInstance = [self.singletonRepository instanceForClass:clazz];
    }
    else {
        classInstance = [[[clazz alloc] init] autorelease];
    }

    [self injectImplementationsToInstance:classInstance];
    
    return classInstance;
}

-(void) injectImplementationsToInstance:(id<NSObject>) classInstance {
    if (!classInstance) return;
    Class clazz = [classInstance class];
    while (clazz) {
        [self _injectImplementationsToInstance:classInstance class:clazz];
        clazz = class_getSuperclass(clazz);
    }
}

-(void) _injectImplementationsToInstance:(id <NSObject>)classInstance class:(Class) clazz {
    unsigned int numberOfIvars = 0;
    Ivar* iVars = class_copyIvarList([clazz class], &numberOfIvars);
    for (int i = 0; i < numberOfIvars; ++i) {
        Ivar ivar = iVars[i];
        
        [self _setValueForIvar:ivar inObjectInstance:classInstance];
    }
    free(iVars);
}

-(void) _setValueForIvar:(Ivar)ivar inObjectInstance:(id) instance {
    
    NSString* ivarName = [self _getIvarName:ivar];
    
    if (![self _isIOCIvar:ivarName]) return;
    
    id (^createInstanceBlock)(void) = ^id(void) {
        return [self _getValueForIvar:ivar withName:ivarName];
    };
    
    id ivarValue;
    
    if ([self _shouldLazyLoadObjects]) {
        ivarValue = [[AppleGuiceInvocationProxy alloc] autorelease];
        ((AppleGuiceInvocationProxy*)ivarValue).createInstanceBlock = createInstanceBlock;
    }
    else {
        ivarValue = createInstanceBlock();
    }
    
    NSAssert(ivarValue != nil, @"Unable to inject implementation to ivar %@ in class %@.", ivarName, NSStringFromClass([instance class]));
    
    [instance setValue:ivarValue forKey:ivarName];
}

-(BOOL) _shouldInjectSingletons {
    return (self.settingsProvider.instanceCreateionPolicy & AppleGuiceInstanceCreationPolicySingletons);
}

-(BOOL) _shouldLazyLoadObjects {
    return (self.settingsProvider.instanceCreateionPolicy & AppleGuiceInstanceCreationPolicyLazyLoad);
}

-(id) _getValueForIvar:(Ivar)ivar withName:(NSString*) ivarName {
    
    const char* ivarTypeEncoding = ivar_getTypeEncoding(ivar);
    
    if ([self _isPrimitiveType:ivarTypeEncoding]) {
        return 0;
    }
    
    NSString* className = [self _classNameFromType:ivarTypeEncoding];
    
    id ivarValue;
    
    if ([self _isProtocol:className]) {
        NSString* protocolName = [self _protocolNameFromType:className];
        ivarValue = [self instanceForProtocol:NSProtocolFromString(protocolName)];
    }
    else if ([self _isArray:ivarTypeEncoding]) {
        NSString* protocolNameFromIvarName = [ivarName substringFromIndex:[self.settingsProvider.iocPrefix length]];
        ivarValue = [self allInstancesForProtocol:NSProtocolFromString(protocolNameFromIvarName)];
    }
    else {
        ivarValue = [self instanceForClass:NSClassFromString(className)];
    }
    
    return ivarValue;
}

-(NSString*) _getIvarName:(Ivar) iVar {
    return [NSString stringWithUTF8String:ivar_getName(iVar)];
}

-(BOOL) _isIOCIvar:(NSString*) iVarName {
    return [iVarName hasPrefix:self.settingsProvider.iocPrefix];
}

-(BOOL) _isProtocol:(NSString*) iVarType {
    return iVarType && [iVarType hasPrefix:@"<"] && [iVarType hasSuffix:@">"];
}

-(NSString*) _protocolNameFromType:(NSString*) iVarType {
    //<xxx>
    return [[iVarType substringFromIndex:1] substringToIndex:[iVarType length] - 2];
}

-(NSString*) _classNameFromType:(const char*) typeEncoding {
    //@"xxx"
    int objectNameLength = strlen(typeEncoding) - 2;
    char* classNameAsCString = malloc(sizeof(char) * strlen(typeEncoding));
    strcpy( classNameAsCString, typeEncoding + (sizeof(char) * 2));
    classNameAsCString[objectNameLength - 1] = '\0';
    NSString* classNameAsNSString = [NSString stringWithUTF8String:classNameAsCString];
    free(classNameAsCString);
    return classNameAsNSString;
}

-(BOOL) _isPrimitiveType:(const char*) ivarTypeEncoding {
    const char* objectEncoding = @encode(id);
    return strncmp(ivarTypeEncoding, objectEncoding, strlen(objectEncoding)) != 0;
}

-(BOOL) _isArray:(const char*) ivarTypeEncoding {
    const char* arrayEncoding = "@\"NSArray\"\0";
    return strcmp(ivarTypeEncoding, arrayEncoding) == 0;
}

- (void) dealloc {
    [_ioc_singletonRepository release];
    [_ioc_protocolLocator release];
    [_ioc_settingsProvider release];
    [super dealloc];
}

@end