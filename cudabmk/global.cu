#include <stdio.h> 
#include <stdint.h>

#include "repeat.h"

const int page_size = 4;	// Scale stride and arrays by page size.


__global__ void global_latency (unsigned long ** my_array, int array_length, int iterations, int ignore_iterations, unsigned long long * duration) {

	unsigned long start_time, end_time;
	unsigned long *j = (unsigned long*)my_array; 
	volatile unsigned long long sum_time;

	sum_time = 0;
	duration[0] = 0;

	for (int k = -ignore_iterations; k < iterations; k++) {
		if (k==0) {
			sum_time = 0; // ignore some iterations: cold icache misses
		}

		start_time = clock();
		repeat256(j=*(unsigned long **)j;)
		end_time = clock();

		sum_time += (end_time - start_time);
	}

	((unsigned long*)my_array)[array_length] = (unsigned long)j;
	((unsigned long*)my_array)[array_length+1] = (unsigned long) sum_time;
	duration[0] = sum_time;
}

int gcf(int a, int b)
{
	if (a == 0) return b;
	return gcf(b % a, a);
}

/* Construct an array of N unsigned longs, with array elements initialized
   so kernel will make stride accesses to the array. Then launch kernel
   10 times, each making iterations*256 global memory accesses. */
void parametric_measure_global(int N, int iterations, int ignore_iterations, int stride) {
	
	int i;
	unsigned long * h_a;
	unsigned long ** d_a;

	unsigned long long * duration;
	unsigned long long * latency;
	unsigned long long latency_sum = 0;

	// Don't die if too much memory was requested.
	if (N > 241600000) { printf ("OOM.\n"); return; }

	/* allocate arrays on CPU */
	h_a = (unsigned long *)malloc(sizeof(unsigned long) * (N+2));
	latency = (unsigned long long *)malloc(sizeof(unsigned long long));

	/* allocate arrays on GPU */
	cudaMalloc ((void **) &d_a, sizeof(unsigned long) * (N+2));
	cudaMalloc ((void **) &duration, sizeof(unsigned long long));

   	/* initialize array elements on CPU with pointers into d_a. */
	
	int step = gcf (stride, N);	// Optimization: Initialize fewer elements.
	for (i = 0; i < N; i += step) {
		// Device pointers are 32-bit on GT200.
		h_a[i] = ((unsigned long)(uintptr_t)d_a) + ((i + stride) % N)*sizeof(unsigned long);	
	}

	h_a[N] = 0;
	h_a[N+1] = 0;


	cudaThreadSynchronize ();

        /* copy array elements from CPU to GPU */
        cudaMemcpy((void *)d_a, (void *)h_a, sizeof(unsigned long) * N, cudaMemcpyHostToDevice);

	cudaThreadSynchronize ();


	/* Launch a multiple of 10 iterations of the same kernel and take the average to eliminate interconnect (TPCs) effects */

	for (int l=0; l <10; l++) {
	
		/* launch kernel*/
		dim3 Db = dim3(1);
		dim3 Dg = dim3(1,1,1);

		// printf("Launch kernel with parameters: %d, N: %d, stride: %d\n", iterations, N, stride); 
		global_latency <<<Dg, Db>>>(d_a, N, iterations, ignore_iterations, duration);

		cudaThreadSynchronize ();

		cudaError_t error_id = cudaGetLastError();
        	if (error_id != cudaSuccess) {
			printf("Error is %s\n", cudaGetErrorString(error_id));
		}

		/* copy results from GPU to CPU */
		cudaThreadSynchronize ();

	        //cudaMemcpy((void *)h_a, (void *)d_a, sizeof(unsigned long) * (N+2), cudaMemcpyDeviceToHost);
        	cudaMemcpy((void *)latency, (void *)duration, sizeof(unsigned long long), cudaMemcpyDeviceToHost);

	        cudaThreadSynchronize ();
		latency_sum+=latency[0];

	}

	/* free memory on GPU */
	cudaFree(d_a);
	cudaFree(duration);
	cudaThreadSynchronize ();

        /*free memory on CPU */
        free(h_a);
        free(latency);

	printf("%f\n", (double)(latency_sum/(10*256.0*iterations)) );

}



/* Test page size. Construct an access pattern of N elements spaced stride apart,
   followed by a gap of stride+offset, followed by N more elements spaced stride
   apart. */
void measure_pagesize(int N, int stride, int offset) {
	
	unsigned long ** h_a;
	unsigned long ** d_a;

	unsigned long long * duration;
	unsigned long long * latency;

	unsigned long long latency_sum = 0;
	
	const int size = N * stride * 2 + offset + stride*2;
	const int iterations = 20;

	// Don't die if too much memory was requested.
	if (size > 241600000) { printf ("OOM.\n"); return; }

	/* allocate array on CPU */
	h_a = (unsigned long **)malloc(8 * size);
	latency = (unsigned long long *)malloc(sizeof(unsigned long long));

	/* allocate array on GPU */
	cudaMalloc ((void **) &d_a, sizeof(unsigned long) * size);
	cudaMalloc ((void **) &duration, sizeof(unsigned long long));

   	/* initialize array elements on CPU */

	for (int i=0;i<N; i++)
		((unsigned long *)h_a)[i*stride] = ((i*stride + stride)*8) + (uintptr_t) d_a;

	((unsigned long *)h_a)[(N-1)*stride] = ((N*stride + offset)*8) + (uintptr_t) d_a;	//point last element to stride+offset

	for (int i=0;i<N; i++)
		((unsigned long *)h_a)[(i+N)*stride+offset] = (((i+N)*stride + offset + stride)*8) + (uintptr_t) d_a;

	((unsigned long *)h_a)[(2*N-1)*stride+offset] = (uintptr_t) d_a;		//wrap around.
	


        cudaThreadSynchronize ();

        /* copy array elements from CPU to GPU */
        cudaMemcpy((void *)d_a, (void *)h_a, sizeof(unsigned long) * size, cudaMemcpyHostToDevice);
        
	cudaThreadSynchronize ();


	for (int l=0; l < 10 ; l++) {
	
		/* launch kernel*/
		dim3 Db = dim3(1);
		dim3 Dg = dim3(1,1,1);

		//printf("Launch kernel with parameters: %d, N: %d, stride: %d\n", iterations, N, stride); 
		global_latency <<<Dg, Db>>>(d_a, N, iterations, 1, duration);

		cudaThreadSynchronize ();

		cudaError_t error_id = cudaGetLastError();
	        if (error_id != cudaSuccess) {
			printf("Error is %s\n", cudaGetErrorString(error_id));
		}

		/* copy results from GPU to CPU */
		cudaThreadSynchronize ();

	        //cudaMemcpy((void *)h_a, (void *)d_a, sizeof(unsigned long) * N, cudaMemcpyDeviceToHost);
	        cudaMemcpy((void *)latency, (void *)duration, sizeof(unsigned long long), cudaMemcpyDeviceToHost);

        	cudaThreadSynchronize ();

		latency_sum+=latency[0];
	}

	/* free memory on GPU */
	cudaFree(d_a);
	cudaFree(duration);
	cudaThreadSynchronize ();


        /*free memory on CPU */
        free(h_a);
        free(latency);
	

	printf("%f\n", (double)(latency_sum/(10.0*256*iterations)));
}




void measure_global1() {

	// we will measure latency of global memory
	// One thread that accesses an array.
	// loads are dependent on the previously loaded values

	int N, iterations, stride; 

	// initialize upper bounds here
	int stride_upper_bound; 

	printf("Global1: Global memory latency for 1 KB array and varying strides.\n");
	printf("   stride (bytes), latency (clocks)\n");


	N=256;		// 131072;
	iterations = 4;
	stride_upper_bound = N; 
	for (stride = 1; stride <= (stride_upper_bound) ; stride+=1) {
		printf ("  %5d, ", stride*8);
		parametric_measure_global(N, iterations, 1, stride);
	}
}


void measure_global5() {

	int N, iterations, stride; 

	// initialize upper bounds here

	printf("\nGlobal5: Global memory latency for %d KB stride.\n", 128 * page_size/4);
	printf("   Array size (KB), latency (clocks)\n");


	iterations = 1;
	stride = 128 * 1024 / 8;
	for (N = (1*128*1024); N <= (16*1024*1024); N += stride) {
		printf ("   %5d, ", N*8/1024 * page_size/4);
		parametric_measure_global(N*page_size/4, iterations, 1, stride *page_size/4);
	}
}

void measure_global_dibs() {

	int N, iterations, stride; 

	// initialize upper bounds here

	printf("\nGlobalDibs: Global memory latency for %d KB stride.\n", 512 * page_size/4);
	printf("   Array size (KB), latency (clocks)\n");


	iterations = 1;
	stride = 4 * 1024 / 8;
	for (N = (1*1024); N <= (2*1024*1024); N += stride) {
		printf ("   %5d, ", N*8/1024 * page_size/4);
		parametric_measure_global(N*page_size/4, iterations, 1, stride *page_size/4);
	}
}

void measure_global6() {
	int N, stride, entries;
	
	printf("\nGlobal6: Testing associativity of L1 TLB.\n");
	printf("   entries, array size (KB), stride (KB), latency\n");

	for (entries = 16; entries <= 128; entries++) {
		for (stride = 1; stride <= (4*1024*1024); stride *= 2 ) {
			for (int substride = 1; substride < 16; substride *= 2 ) {
				int stride2 = stride * sqrt(sqrt(substride)) + 0.5;
				N = entries * stride2;
				
				printf ("   %d, %7.2f, %7f, ", entries, N*8/1024.0*page_size/4, stride2*8/1024.0*page_size/4);
				parametric_measure_global(N*page_size/4, 4, 1, stride2*page_size/4);
			}
		}
	}
}

void measure_global4() //TODO
{
	printf ("\nGlobal4: Measuring L2 TLB page size using %d MB stride\n", 2 * page_size/4);
	printf ("  offset (bytes), latency (clocks)\n");
		
	// Small offsets (approx. page size) are interesting. Search much bigger offsets to
	// ensure nothing else interesting happens.
	for (int offset = -8192/8; offset <= (2097152+1536)/8; offset += (offset < 1536) ? 128/8 : 4096/8)
	{
		printf ("  %d, ", offset*8 *page_size/4);
		measure_pagesize(10, 2097152/8 *page_size/4, offset* page_size/4);
	}
	
}

__global__ void ptw_thread_kernel(unsigned long ** gpuArr, unsigned long **largeGPUArr, unsigned long gpuArrSize, 
								  int iterations, int ignore_iterations, unsigned long long * duration, 
								  int numAccess, int numThreads, int N) {
	unsigned long start_time, end_time;
	unsigned long *j = (unsigned long*)(gpuArr+(threadIdx.x*N/sizeof(unsigned long))); 
	volatile unsigned long long sum_time;

	sum_time = 0;
	duration[0] = 0;
	if (threadIdx.x == 0) {
		for (int i = 0; i<512*1024*1024/8; i++) {
			largeGPUArr[i] = (unsigned long *) i+1; //scam
		}
	}
	__syncthreads();

	for (int k = -ignore_iterations; k < iterations; k++) {
		if (k==0) {
			sum_time = 0; // ignore some iterations: cold icache misses
		}

		// Do our striding
		//printf("Thread id: %d\n", threadIdx.x);

		start_time = clock();
		//printf("Thread id 334: %d\n", threadIdx.x);
		repeat256(j=*(unsigned long **)j;__syncthreads();)
		//printf("Thread id 336: %d\n", threadIdx.x);
		end_time = clock();
		//printf("Thread id 338: %d\n", threadIdx.x);

		sum_time += (end_time - start_time);
		//printf("Time: %lld Thread ID: %d\n", sum_time, threadIdx.x);
	}

	((unsigned long*)gpuArr)[gpuArrSize + threadIdx.x] = (unsigned long)j;
	((unsigned long*)gpuArr)[gpuArrSize+ numThreads + threadIdx.x] = (unsigned long) sum_time;
	if (threadIdx.x == numThreads-1) {
		duration[0] = sum_time;
	}
}

void measure_ptw_thread(unsigned long numThreads) {
	// printf("\n Measuring # of PTW Threads with %d threads used...\n", numThreads);

	unsigned long start_time, end_time;

	unsigned long *cpuArr;
	unsigned long **gpuArr;
	unsigned long N = 128*1024;
	unsigned long numAccess = 256; // accesses per thread, 
	unsigned long totalMem = N * numThreads * numAccess;

	unsigned long *largeCPUArr;
	unsigned long **largeGPUArr;

	unsigned long long * duration;
	unsigned long long * latency;
	unsigned long long latency_sum = 0;
	latency = (unsigned long long *)malloc(sizeof(unsigned long long));
	cudaMalloc ((void **) &duration, sizeof(unsigned long long));

	// malloc for cpu array
	cpuArr = (unsigned long *)malloc(totalMem);
	largeCPUArr = (unsigned long *)malloc(512*1024*1024);

	cudaMalloc ((void **) &gpuArr, totalMem + sizeof(unsigned long) * (numThreads * 2 + 5)); // 5 because we don't trust ourselves
	cudaMalloc ((void **) &largeGPUArr, 512*1024*1024);

	for (long i = 0; i < totalMem/(sizeof(unsigned long)); i += N/(sizeof(unsigned long))) {
		// Device pointers are 64-bit on what we are using.
		cpuArr[i] = ((unsigned long)(uintptr_t)gpuArr) + ((i + (numThreads * N/sizeof(unsigned long)))%N * sizeof(unsigned long));
	}
	for (long i = 0; i < 512*1024*1024/8; i++) {
		largeCPUArr[i] = i;
	}

	cudaThreadSynchronize ();

    /* copy array elements from CPU to GPU */
    cudaMemcpy((void *)gpuArr, (void *)cpuArr, totalMem, cudaMemcpyHostToDevice);
    cudaMemcpy((void *)largeGPUArr, (void *)largeCPUArr, 512*1024*1024, cudaMemcpyHostToDevice);

	cudaThreadSynchronize ();

	// h_a[N] = 0; we don't need this
	// h_a[N+1] = 0;

	

	for (int l=0; l <10; l++) {
		/* launch kernel*/
		dim3 Db = dim3(numThreads);
		dim3 Dg = dim3(1);
		// Pray and launch our kernel
		ptw_thread_kernel <<<Dg, Db>>>(gpuArr, largeGPUArr, totalMem/sizeof(unsigned long), 1, 0, duration, numAccess, numThreads, N); //don't ignore the first iteration
		cudaThreadSynchronize ();

		cudaError_t error_id = cudaGetLastError();
    	if (error_id != cudaSuccess) {
			printf("Error is %s\n", cudaGetErrorString(error_id));
		}

		cudaThreadSynchronize ();

		cudaMemcpy((void *)latency, (void *)duration, sizeof(unsigned long long), cudaMemcpyDeviceToHost);

	    cudaThreadSynchronize ();

		latency_sum+=latency[0];

	}

	/* free memory on GPU */
	cudaFree(gpuArr);
	cudaFree(duration);
	cudaThreadSynchronize ();


    /*free memory on CPU */
    free(cpuArr);
    free(latency);

    printf("%d,%f\n", numThreads, (double)(latency_sum/(10*256.0)) );
	

}

int main() {
	printf("Assuming page size is %d KB\n", page_size);
	// printf("%d\n", sizeof(long));
	// printf("%d\n", sizeof(long long));
	// measure_global_dibs();
	// measure_global1();
	// measure_global4();
	// measure_global5();
	// measure_global6();
	for (unsigned long i = 1; i<=64; i++) {
		measure_ptw_thread(i);
	}
	return 0;
}
