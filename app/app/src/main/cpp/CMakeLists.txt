cmake_minimum_required(VERSION 3.22.1)
project("soppsu")

add_library(soppsu SHARED
        sopp_ctl.c
        jni_bridge.cpp)

find_library(log-lib log)

target_link_libraries(soppsu ${log-lib})
