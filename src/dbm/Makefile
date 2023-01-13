.PHONY : all clean

all: dbm_miniapp.x

clean:
	rm -fv *.o */*.o ../offload/*.o

realclean: clean
	rm -fv *.x

CFLAGS := -fopenmp -g -O3 -march=native -Wall -Wextra -Wno-vla-parameter

HIP_PLATFORM = $(shell hipconfig --platform)

GPU_CC = hipcc
ifeq (${HIP_PLATFORM}, nvidia)
ARCH := sm_80
HIP_PATH := /global/common/software/nersc/easybuild/perlmutter/21.10/software/hip/5.3.2
HIP_BACKEND = __HIP_PLATFORM_NVIDIA__
GPU_FLAGS := -g -O3 -lineinfo -arch $(ARCH) -Wno-deprecated-gpu-targets -Xcompiler "$(CFLAGS)" -D__OFFLOAD_HIP -D$(HIP_BACKEND)
else ifeq (${HIP_PLATFORM}, amd)
ARCH := gfx90a
HIP_PATH := $(ROCM_PATH)
HIP_BACKEND = __HIP_PLATFORM_AMD__
LIBARCHFLAG := -lamdhip64 -lrocblas
GPU_FLAGS := -fPIE -g -O3 --offload-arch=$(ARCH) -Wall -Wextra -Werror -D__OFFLOAD_HIP -D$(HIP_BACKEND)
endif


LIBS += -fopenmp -ldl -lstdc++ -lc -lm

ALL_HEADERS := $(shell find . -name "*.h") $(shell find ../offload/ -name "*.h")
ALL_OBJECTS := ../offload/offload_library.o \
        dbm_distribution.o \
        dbm_library.o \
        dbm_matrix.o \
        dbm_mempool.o \
        dbm_mpi.o \
        dbm_multiply.o \
        dbm_multiply_comm.o \
        dbm_multiply_cpu.o \
        dbm_shard.o


LIBS += -L${HIP_PATH}/hipblas/lib -L${HIP_PATH}/lib $(LIBARCHFLAG) -lhipblas
CFLAGS += -I${HIP_PATH}/include -D__OFFLOAD_HIP -D$(HIP_BACKEND)
ALL_OBJECTS += dbm_multiply_gpu.o

%.o: %.cpp $(ALL_HEADERS)
	cd $(dir $<); $(GPU_CC) -c $(GPU_FLAGS) $(notdir $<)

dbm_miniapp.x: dbm_multiply_gpu_kernel.o dbm_miniapp.o $(ALL_OBJECTS)
	$(CC) $(CFLAGS) -o $@ $^ $(LIBS)

#EOF
