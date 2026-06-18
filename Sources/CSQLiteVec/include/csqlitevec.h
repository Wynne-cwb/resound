// 伞头文件：把系统 sqlite3 C API 和 sqlite-vec 的注册函数一起暴露给 Swift。
// 编译时定义 SQLITE_CORE，sqlite-vec.c 会直接链系统 libsqlite3，绕开扩展加载限制。
#include <sqlite3.h>
#include "sqlite-vec.h"
