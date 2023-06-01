.PHONY : all clean

all: grid_miniapp.x grid_unittest.x

clean:
	rm -fv *.o */*.o *.x ../offload/*.o

CFLAGS := -D__HIP_PLATFORM_NVIDIA__ -Xcompiler -fopenmp -g -O3 #-march=native -Wall -Wextra
NVFLAGS :=  -g -O3 -lineinfo -arch sm_80 -Wno-deprecated-gpu-targets -D__OFFLOAD_HIP "$(CFLAGS)"
LIBS := -lm -lblas

ALL_HEADERS := $(shell find . -name "*.h") $(shell find ../offload/ -name "*.h")
ALL_OBJECTS := ../offload/offload_buffer.o \
        ../offload/offload_library.o \
        grid_replay.o \
        grid_task_list.o \
        common/grid_library.o \
        common/grid_basis_set.o \
        common/grid_sphere_cache.o \
        ref/grid_ref_task_list.o \
        ref/grid_ref_collocate.o \
        ref/grid_ref_integrate.o \
        ref/grid_ref_prepare_pab.o \
        cpu/grid_context_cpu.o \
        cpu/coefficients.o \
        cpu/grid_collocate_dgemm.o \
        cpu/grid_integrate_dgemm.o \
        cpu/non_orthorombic_corrections.o \
        cpu/utils.o \
        cpu/collocation_integration.o \
        cpu/grid_context_cpu.o \
        cpu/grid_prepare_pab_dgemm.o \
        cpu/tensor_local.o

# Enable Cuda when nvcc compiler is present.
NVCC := hipcc
#NVCC := $(shell which nvcc)

ifneq ($(NVCC),)
LIBS += -L/opt/nvidia/hpc_sdk/Linux_x86_64/22.7/math_libs/11.7/lib64 -lcudart -lcuda -lcublas -L${CUDA_PATH}/lib64
CFLAGS += -I${HIP_PATH}/include -D__OFFLOAD_HIP
ALL_OBJECTS += gpu/grid_gpu_task_list.o \
        gpu/grid_gpu_collocate.o \
        gpu/grid_gpu_integrate.o
ALL_OBJECTS += hip/grid_hip_context.o \
        hip/grid_hip_collocate.o \
        hip/grid_hip_integrate.o

%.o: %.cu $(ALL_HEADERS)
	cd $(dir $<); $(NVCC) -c $(NVFLAGS) $(notdir $<)
endif

%.o: %.c $(ALL_HEADERS)
	cd $(dir $<); $(NVCC) -c $(CFLAGS) $(notdir $<)

grid_miniapp.x: grid_miniapp.o $(ALL_OBJECTS)
	$(NVCC) $(CFLAGS) -o $@ $^ $(LIBS)

grid_unittest.x: grid_unittest.o $(ALL_OBJECTS)
	$(NVCC) $(CFLAGS) -o $@ $^ $(LIBS)

#EOF
