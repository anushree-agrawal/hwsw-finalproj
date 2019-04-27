int array_size = 800;
for (i = 0; i < array_size; i++) {
    int t = i + stride;
    if (t >= array_size) t %= stride;
    host_array[i] = (int)device_array + 4*t;
    }
cudaMemcpy(device_array, host_array, array_size, cudaMemcpyDeviceToHost);