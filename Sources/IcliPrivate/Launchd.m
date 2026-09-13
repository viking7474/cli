#import "IcliPrivate.h"
#import <Foundation/Foundation.h>
#import <xpc/xpc.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

// launchd's bootstrap pipe protocol, as used by launchctl(1). The routine
// numbers are stable across the supported legacy/current layouts; transport
// and default-domain behavior changed in iOS 15, while user sessions arrived
// in iOS 16. Keep version-dependent libxpc entry points runtime-resolved so an
// iOS 13 process never has to bind symbols introduced by later firmware.
enum {
    RoutineLoad = 800,
    RoutineUnload = 801,
    RoutineEnable = 808,
    RoutineDisable = 809,
    RoutineStop = 814,
    RoutineList = 815,
    RoutinePrint = 828,
};

enum { DomainSystem = 1, DomainUser = 2, DomainCaller = 7 };

struct _os_alloc_once_s { long once; void *ptr; };
struct xpc_global_data { uint64_t a; uint64_t xpc_flags; mach_port_t task_bootstrap_port; xpc_object_t xpc_bootstrap_pipe; };

typedef int (*IcliXPCInterfaceRoutine)(xpc_object_t, uint64_t, xpc_object_t, xpc_object_t *, uint64_t);
typedef int (*IcliXPCPipeRoutine)(xpc_object_t, xpc_object_t, xpc_object_t *);
typedef const char *(*IcliXPCStrerror)(int);
typedef uint64_t (*IcliForegroundUID)(uint64_t);
typedef xpc_object_t (*IcliXPCShmemCreate)(void *, size_t);

static NSInteger systemMajorVersion(void) {
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
}

static const char *launchdStrerror(int error) {
    static IcliXPCStrerror function;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ function = (IcliXPCStrerror)dlsym(RTLD_DEFAULT, "xpc_strerror"); });
    return function ? function(error) : strerror(error);
}

static struct xpc_global_data *xpcGlobalData(void) {
    struct _os_alloc_once_s *table = dlsym(RTLD_DEFAULT, "_os_alloc_once_table");
    return table ? table[1].ptr : NULL;
}

static uint64_t foregroundUID(void) {
    if (systemMajorVersion() < 16) return 0;
    static IcliForegroundUID function;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ function = (IcliForegroundUID)dlsym(RTLD_DEFAULT, "xpc_user_sessions_get_foreground_uid"); });
    return function ? function(0) : 0;
}

static char *launchdJSON(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return data ? strndup(data.bytes, data.length) : NULL;
}

static id objectFromXPC(xpc_object_t value) {
    xpc_type_t type = xpc_get_type(value);
    if (type == XPC_TYPE_STRING) return @(xpc_string_get_string_ptr(value));
    if (type == XPC_TYPE_INT64) return @(xpc_int64_get_value(value));
    if (type == XPC_TYPE_UINT64) return @(xpc_uint64_get_value(value));
    if (type == XPC_TYPE_DOUBLE) return @(xpc_double_get_value(value));
    if (type == XPC_TYPE_BOOL) return @(xpc_bool_get_value(value));
    if (type == XPC_TYPE_ARRAY) {
        NSMutableArray *array = [NSMutableArray array];
        xpc_array_apply(value, ^bool(size_t index, xpc_object_t item) { [array addObject:objectFromXPC(item)]; return true; });
        return array;
    }
    if (type == XPC_TYPE_DICTIONARY) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        xpc_dictionary_apply(value, ^bool(const char *key, xpc_object_t item) { dict[@(key)] = objectFromXPC(item); return true; });
        return dict;
    }
    return [NSString stringWithFormat:@"<%s>", xpc_type_get_name(type)];
}

/// Returns 0 or an errno / launchd error code. iOS 15 introduced
/// _xpc_pipe_interface_routine; iOS 13/14 use xpc_pipe_routine instead.
static int launchdRoutine(uint64_t routine, uint64_t domain, uint64_t handle, xpc_object_t message, xpc_object_t *reply) {
    struct xpc_global_data *global = xpcGlobalData();
    if (!global || !global->xpc_bootstrap_pipe) return ENXIO;
    xpc_dictionary_set_uint64(message, "type", domain);
    xpc_dictionary_set_uint64(message, "handle", handle);
    xpc_dictionary_set_uint64(message, "subsystem", routine >> 8);
    xpc_dictionary_set_uint64(message, "routine", routine);

    xpc_object_t response = NULL;
    int status = ENOSYS;
    if (systemMajorVersion() >= 15) {
        IcliXPCInterfaceRoutine function = (IcliXPCInterfaceRoutine)dlsym(RTLD_DEFAULT, "_xpc_pipe_interface_routine");
        if (function) {
            status = function(global->xpc_bootstrap_pipe, 0, message, &response, 0);
        } else {
            IcliXPCPipeRoutine legacy = (IcliXPCPipeRoutine)dlsym(RTLD_DEFAULT, "xpc_pipe_routine");
            if (legacy) status = legacy(global->xpc_bootstrap_pipe, message, &response);
        }
    } else {
        IcliXPCPipeRoutine function = (IcliXPCPipeRoutine)dlsym(RTLD_DEFAULT, "xpc_pipe_routine");
        if (function) status = function(global->xpc_bootstrap_pipe, message, &response);
    }
    if (status == 0 && response) status = (int)xpc_dictionary_get_int64(response, "error");
    if (reply) *reply = response;
    return status;
}

const char *icli_launchd_strerror(int error) {
    return launchdStrerror(error);
}

static NSDictionary *errorsFromReply(xpc_object_t reply) {
    NSMutableDictionary *errors = [NSMutableDictionary dictionary];
    xpc_object_t table = reply ? xpc_dictionary_get_value(reply, "errors") : NULL;
    if (table && xpc_get_type(table) == XPC_TYPE_DICTIONARY) {
        xpc_dictionary_apply(table, ^bool(const char *key, xpc_object_t value) {
            if (xpc_get_type(value) == XPC_TYPE_INT64) {
                int code = (int)xpc_int64_get_value(value);
                errors[@(key)] = @{@"code": @(code), @"message": @(launchdStrerror(code))};
            }
            return true;
        });
    }
    return errors;
}

static uint64_t defaultLoadDomain(void) {
    // Procursus launchctl uses the system domain before iOS 15 and the caller
    // domain from iOS 15 onward.
    return systemMajorVersion() >= 15 ? DomainCaller : DomainSystem;
}

char *icli_launchd_load_json(const char **paths, int count, bool load, bool override) {
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_object_t array = xpc_array_create(NULL, 0);
    for (int i = 0; i < count; i++) xpc_array_set_string(array, XPC_ARRAY_APPEND, paths[i]);
    xpc_dictionary_set_value(message, "paths", array);
    xpc_dictionary_set_bool(message, "legacy-load", true);
    xpc_dictionary_set_bool(message, load ? "enable" : "disable", override);
    if (!load && systemMajorVersion() >= 15) xpc_dictionary_set_bool(message, "no-einprogress", true);
    xpc_object_t reply = NULL;
    int status = launchdRoutine(load ? RoutineLoad : RoutineUnload, defaultLoadDomain(), 0, message, &reply);
    return launchdJSON(@{@"status": @(status), @"message": @(launchdStrerror(status)), @"errors": errorsFromReply(reply)});
}

char *icli_launchd_enable_json(const char *label, bool enable) {
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_object_t names = xpc_array_create(NULL, 0);
    xpc_array_set_string(names, XPC_ARRAY_APPEND, label);
    xpc_dictionary_set_value(message, "names", names);
    xpc_object_t reply = NULL;
    int status = launchdRoutine(enable ? RoutineEnable : RoutineDisable, DomainSystem, 0, message, &reply);
    return launchdJSON(@{@"status": @(status), @"message": @(launchdStrerror(status)), @"errors": errorsFromReply(reply)});
}

/// launchd's view of one label. iOS 16+ may carry the live service in the
/// foreground user's domain; iOS 13-15 only query the system domain here.
char *icli_launchd_service_json(const char *label) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    xpc_object_t systemMessage = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(systemMessage, "name", label);
    xpc_object_t systemReply = NULL;
    int systemStatus = launchdRoutine(RoutineList, DomainSystem, 0, systemMessage, &systemReply);
    NSMutableDictionary *systemRecord = [@{@"status": @(systemStatus), @"message": @(launchdStrerror(systemStatus))} mutableCopy];
    xpc_object_t systemService = systemStatus == 0 && systemReply ? xpc_dictionary_get_value(systemReply, "service") : NULL;
    if (systemService && xpc_get_type(systemService) == XPC_TYPE_DICTIONARY) systemRecord[@"service"] = objectFromXPC(systemService);
    result[@"system"] = systemRecord;

    uint64_t uid = foregroundUID();
    if (uid) {
        xpc_object_t userMessage = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(userMessage, "name", label);
        xpc_object_t userReply = NULL;
        int userStatus = launchdRoutine(RoutineList, DomainUser, uid, userMessage, &userReply);
        NSMutableDictionary *userRecord = [@{@"status": @(userStatus), @"message": @(launchdStrerror(userStatus))} mutableCopy];
        xpc_object_t userService = userStatus == 0 && userReply ? xpc_dictionary_get_value(userReply, "service") : NULL;
        if (userService && xpc_get_type(userService) == XPC_TYPE_DICTIONARY) userRecord[@"service"] = objectFromXPC(userService);
        result[@"user"] = userRecord;
    } else {
        result[@"user"] = @{@"status": @(ENOTSUP), @"message": @"foreground user launchd domain unavailable on this iOS version"};
    }
    return launchdJSON(result);
}

static NSMutableDictionary *disabledOverridesFromText(NSString *text) {
    NSMutableDictionary *overrides = [NSMutableDictionary dictionary];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSArray *parts = [line componentsSeparatedByString:@"\" => "];
        if (parts.count != 2) continue;
        NSString *name = [parts[0] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\t \""]];
        NSString *state = [parts[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        overrides[name] = @([state isEqualToString:@"disabled"]);
    }
    return overrides;
}

static NSString *readTextFromFD(int fd) {
    if (lseek(fd, 0, SEEK_SET) < 0) return @"";
    NSMutableData *data = [NSMutableData data];
    char buffer[8192];
    for (;;) {
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count > 0) [data appendBytes:buffer length:(NSUInteger)count];
        else if (count == 0) break;
        else if (errno != EINTR) break;
    }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

/// The system domain's disabled-service overrides: {label: true when disabled}.
/// launchctl uses an fd for print output on iOS 13/14 and shared memory on iOS
/// 15+, so mirror that split instead of binding xpc_shmem_create on iOS 13.
char *icli_launchd_disabled_json(void) {
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_bool(message, "disabled", true);
    xpc_object_t reply = NULL;
    int status = ENOSYS;
    NSString *text = @"";

    if (systemMajorVersion() >= 15) {
        vm_size_t size = 0x100000;
        vm_address_t address = 0;
        IcliXPCShmemCreate createShmem = (IcliXPCShmemCreate)dlsym(RTLD_DEFAULT, "xpc_shmem_create");
        if (!createShmem) {
            status = ENOSYS;
        } else if (vm_allocate(mach_task_self(), &address, size, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) {
            status = ENOMEM;
        } else {
            xpc_dictionary_set_value(message, "shmem", createShmem((void *)address, size));
            status = launchdRoutine(RoutinePrint, DomainSystem, 0, message, &reply);
            if (status == 0 && reply) {
                uint64_t written = xpc_dictionary_get_uint64(reply, "bytes-written");
                text = [[NSString alloc] initWithBytes:(void *)address length:MIN(written, size) encoding:NSUTF8StringEncoding] ?: @"";
            }
            vm_deallocate(mach_task_self(), address, size);
        }
    } else {
        char path[] = "/tmp/icli-launchd.XXXXXX";
        int fd = mkstemp(path);
        if (fd < 0) {
            status = errno;
        } else {
            unlink(path);
            xpc_dictionary_set_fd(message, "fd", fd);
            status = launchdRoutine(RoutinePrint, DomainSystem, 0, message, &reply);
            if (status == 0) text = readTextFromFD(fd);
            close(fd);
        }
    }

    return launchdJSON(@{@"status": @(status), @"message": @(launchdStrerror(status)), @"disabled": disabledOverridesFromText(text)});
}

/// `launchctl stop` for a system-domain label; launchd relaunches KeepAlive
/// services such as SpringBoard.
int icli_launchd_stop(const char *label) {
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(message, "name", label);
    return launchdRoutine(RoutineStop, DomainSystem, 0, message, NULL);
}
