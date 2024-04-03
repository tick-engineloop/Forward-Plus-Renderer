cmake_minimum_required(VERSION 3.20)
project(ForwardPlusRenderer VERSION 0.1.0)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(GLEW REQUIRED)
find_package(glm REQUIRED)
find_package(glfw3 REQUIRED)
find_package(DevIL REQUIRED)
find_package(assimp REQUIRED)

include_directories("/usr/include")

set(SOURCE_FILES "source/shader.cpp"
"source/camera.cpp"
"source/mesh.cpp"
"source/model.cpp"
"source/main.cpp")

add_executable(${CMAKE_PROJECT_NAME} ${SOURCE_FILES})

set(LIBS ${LIBS} GLEW GL glfw IL assimp)
target_link_libraries(${CMAKE_PROJECT_NAME} ${LIBS})

# copy shader files to build directory
file(GLOB SHADERS
    "${CMAKE_SOURCE_DIR}/source/shaders/*.glsl"
)
foreach(SHADER ${SHADERS})
    if(UNIX)
        file(COPY ${SHADER} DESTINATION ${CMAKE_CURRENT_BINARY_DIR}/)
    endif(UNIX)
endforeach(SHADER)