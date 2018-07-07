#include "CudaHandleError.h"
#include "Parameters.h"
#include <Windows.h>
#include <iostream>
#include "Timer.h"
#include "Vertex.h"
#include "Parameters.h"
#include "TsdfVolume.cuh"

namespace tsdf {
	float3 size;
	float3 center;
	float3 volumeSize;
	float3 offset;

	float* volume_device;
	UINT8* volumeBin_device;
	UINT16* depth_device;
	uchar4* color_device;
	Transformation* depthTrans_device;
	Transformation* colorTrans_device;
	Intrinsics* depthIntrinsics_device;
	Intrinsics* colorIntrinsics_device;
	Vertex* vertex_device;
	int* count_device;
}
using namespace tsdf;

#if VOLUME == 256
CUDA_CALLABLE_MEMBER __forceinline__ int devicePid(int x, int y) {
	return (x & 15) | ((y & 15) << 4) | ((x >> 4) << 8) | ((y >> 4) << 12);
}

CUDA_CALLABLE_MEMBER __forceinline__ int deviceVid(int x, int y, int z) {
	return (x & 15) | ((y & 15) << 4) | ((z & 15) << 8) | ((x >> 4) << 12) | ((y >> 4) << 16) | ((z >> 4) << 20);
}
#elif VOLUME == 512
CUDA_CALLABLE_MEMBER __forceinline__ int devicePid(int x, int y) {
	return (x & 15) | ((y & 15) << 4) | ((x >> 4) << 8) | ((y >> 4) << 13);
}

CUDA_CALLABLE_MEMBER __forceinline__ int deviceVid(int x, int y, int z) {
	return (x & 15) | ((y & 15) << 4) | ((z & 15) << 8) | ((x >> 4) << 12) | ((y >> 4) << 17) | ((z >> 4) << 22);
}
#endif


extern "C"
void cudaInitVolume(float sizeX, float sizeY, float sizeZ, float centerX, float centerY, float centerZ) {
	size = make_float3(sizeX, sizeY, sizeZ);
	center = make_float3(centerX, centerY, centerZ);
	volumeSize = size * (1.0 / VOLUME);
	offset = center - size * 0.5;
	HANDLE_ERROR(cudaMalloc(&volume_device, VOLUME * VOLUME * VOLUME * sizeof(float)));
	HANDLE_ERROR(cudaMalloc(&volumeBin_device, VOLUME * VOLUME * VOLUME * sizeof(UINT8)));
	HANDLE_ERROR(cudaMalloc(&depth_device, MAX_CAMERAS * DEPTH_H * DEPTH_W * sizeof(UINT16)));
	HANDLE_ERROR(cudaMalloc(&color_device, MAX_CAMERAS * COLOR_H * COLOR_W * sizeof(uchar4)));
	HANDLE_ERROR(cudaMalloc(&depthTrans_device, MAX_CAMERAS * sizeof(Transformation)));
	HANDLE_ERROR(cudaMalloc(&colorTrans_device, MAX_CAMERAS * sizeof(Transformation)));
	HANDLE_ERROR(cudaMalloc(&depthIntrinsics_device, MAX_CAMERAS * sizeof(Intrinsics)));
	HANDLE_ERROR(cudaMalloc(&colorIntrinsics_device, MAX_CAMERAS * sizeof(Intrinsics)));
	HANDLE_ERROR(cudaMalloc(&vertex_device, MAX_VERTEX * sizeof(Vertex)));
	HANDLE_ERROR(cudaMalloc(&count_device, VOLUME * VOLUME * sizeof(int)));
}

extern "C"
void cudaReleaseVolume() {
	HANDLE_ERROR(cudaFree(volume_device));
	HANDLE_ERROR(cudaFree(volumeBin_device));
	HANDLE_ERROR(cudaFree(depth_device));
	HANDLE_ERROR(cudaFree(color_device));
	HANDLE_ERROR(cudaFree(depthTrans_device));
	HANDLE_ERROR(cudaFree(colorTrans_device));
	HANDLE_ERROR(cudaFree(depthIntrinsics_device));
	HANDLE_ERROR(cudaFree(colorIntrinsics_device));
	HANDLE_ERROR(cudaFree(vertex_device));
	HANDLE_ERROR(cudaFree(count_device));
}

__global__ void kernelIntegrateDepth(int cameras, float* volume, UINT8* volumeBin, Transformation* transformation, Intrinsics* intrinsics, float* depthMap, float3 volumeSize, float3 offset) {
	int x = threadIdx.x + blockIdx.x * blockDim.x;
	int y = threadIdx.y + blockIdx.y * blockDim.y;

	if (x >= VOLUME || y >= VOLUME) {
		return;
	}

	const float TRANC_DIST_M = 3.0 * max(volumeSize.x, max(volumeSize.y, volumeSize.z));

	struct VolumePara {
		float tsdf = 0;
		UINT8 cnt = 0;
		UINT8 bin = 0;
	} volumePara[VOLUME];

	for (int i = 0; i < cameras; i++) {
		float3 ori = make_float3(x, y, -1) * volumeSize + offset;
		float3 pos = transformation[i].translate(ori);
		float3 deltaZ = transformation[i].deltaZ() * volumeSize;

		for (int z = 0; z < VOLUME; z++) {
			float tsdf = -1;
			pos = pos + deltaZ;
			int2 pixel = intrinsics[i].translate(pos);

			if (pos.z > 0 && 0 <= pixel.x && pixel.x < DEPTH_W && 0 <= pixel.y && pixel.y < DEPTH_H) {
				UINT16 depth = depthMap[(i * DEPTH_H + pixel.y) * DEPTH_W + pixel.x];

				if (depth != 0) {
					float sdf = depth * 0.001 - pos.z;

					if (sdf >= -TRANC_DIST_M) {
						tsdf = sdf / TRANC_DIST_M;
					}
				}
			}

			if (tsdf != -1) {
				volumePara[z].tsdf += tsdf;
				volumePara[z].bin |= (1 << i);
				volumePara[z].cnt++;
			}
		}
	}

	for (int z = 0; z < VOLUME; z++) {
		int id = deviceVid(x, y, z);
		if (volumePara[z].bin != 0) {
			volume[id] = volumePara[z].tsdf / volumePara[z].cnt;
		} else {
			volume[id] = -1;
		}
		volumeBin[id] = volumePara[z].bin;
	}
}

__device__ __forceinline__ UINT16 deviceGetCubeIndex(float* volume, int x, int y, int z) {
	if (x + 1 >= VOLUME) return 0;
	if (y + 1 >= VOLUME) return 0;
	if (z + 1 >= VOLUME) return 0;
	if (volume[deviceVid(x + 0, y + 0, z + 0)] == -1) return 0;
	if (volume[deviceVid(x + 1, y + 0, z + 0)] == -1) return 0;
	if (volume[deviceVid(x + 0, y + 1, z + 0)] == -1) return 0;
	if (volume[deviceVid(x + 1, y + 1, z + 0)] == -1) return 0;
	if (volume[deviceVid(x + 0, y + 0, z + 1)] == -1) return 0;
	if (volume[deviceVid(x + 1, y + 0, z + 1)] == -1) return 0;
	if (volume[deviceVid(x + 0, y + 1, z + 1)] == -1) return 0;
	if (volume[deviceVid(x + 1, y + 1, z + 1)] == -1) return 0;
	UINT16 index = 0;
	if (volume[deviceVid(x + 0, y + 0, z + 0)] < 0) index |= 1;
	if (volume[deviceVid(x + 1, y + 0, z + 0)] < 0) index |= 2;
	if (volume[deviceVid(x + 0, y + 1, z + 0)] < 0) index |= 8;
	if (volume[deviceVid(x + 1, y + 1, z + 0)] < 0) index |= 4;
	if (volume[deviceVid(x + 0, y + 0, z + 1)] < 0) index |= 16;
	if (volume[deviceVid(x + 1, y + 0, z + 1)] < 0) index |= 32;
	if (volume[deviceVid(x + 0, y + 1, z + 1)] < 0) index |= 128;
	if (volume[deviceVid(x + 1, y + 1, z + 1)] < 0) index |= 64;
	return index;
}

__global__ void kernelMarchingCubesCount(float* volume, int* count) {
	int x = threadIdx.x + blockIdx.x * blockDim.x;
	int y = threadIdx.y + blockIdx.y * blockDim.y;

	int cnt = 0;
	for (int z = 0; z + 1 < VOLUME; z++) {
		cnt += triNumber_device[deviceGetCubeIndex(volume, x, y, z)];
	}
	count[devicePid(x, y)] = cnt;
}

__device__ __forceinline__ float3 deviceCalnEdgePoint(float* volume, int x, int y, int z, int dx, int dy, int dz) {
	float v1 = volume[deviceVid(x, y, z)];
	float v2 = volume[deviceVid(x + dx, y + dy, z + dz)];
	if ((v1 < 0) ^ (v2 < 0)) {
		float k =  v1 / (v1 - v2);
		return make_float3(x + k * dx, y + k * dy, z + k * dz);
	}
	return float3();
}

__device__ __forceinline__ uchar4 calnColor(int cameras, UINT8 bin, float3 ori, Transformation* transformation, Intrinsics* intrinsics, uchar4* colorMap) {
	short4 colorSum = short4();
	int cnt = 0;
	for (int i = 0; i < cameras; i++) {
		if ((bin >> i) & 1) {
			float3 pos = transformation[i].translate(ori);
			int2 pixel = intrinsics[i].translate(pos);
			if (0 <= pixel.x && pixel.x < COLOR_W && 0 <= pixel.y && pixel.y < COLOR_H) {
				cnt++;
				uchar4 tmp = colorMap[(i * COLOR_H + pixel.y) * COLOR_W + pixel.x];
				colorSum.x += tmp.x;
				colorSum.y += tmp.y;
				colorSum.z += tmp.z;
			}
		}
	}
	if (cnt == 0) {
		return uchar4();
	}
	return make_uchar4(colorSum.x / cnt, colorSum.y / cnt, colorSum.z / cnt, 0);
}

__global__ void kernelMarchingCubes(int cameras, float* volume, UINT8* volumeBin, int* count, Vertex* vertex, Transformation* transformation, Intrinsics* intrinsics, uchar4* colorMap, float3 volumeSize, float3 offset) {
	int x = threadIdx.x + blockIdx.x * blockDim.x;
	int y = threadIdx.y + blockIdx.y * blockDim.y;

	if (x + 1 >= VOLUME || y + 1 >= VOLUME) {
		return;
	}	

	float3 pos[12];
	float3 posBuffer[6];
	Vertex* vtx = vertex + count[devicePid(x, y)] * 3;

	for (int z = 0; z + 1 < VOLUME; z++) {
		int cubeId = deviceGetCubeIndex(volume, x, y, z);

		if (triTable_device[cubeId][0] != -1) {
			int id = deviceVid(x, y, z);
			pos[0] = deviceCalnEdgePoint(volume, x + 0, y + 0, z + 0, 1, 0, 0);
			pos[1] = deviceCalnEdgePoint(volume, x + 1, y + 0, z + 0, 0, 1, 0);
			pos[2] = deviceCalnEdgePoint(volume, x + 0, y + 1, z + 0, 1, 0, 0);
			pos[3] = deviceCalnEdgePoint(volume, x + 0, y + 0, z + 0, 0, 1, 0);

			pos[4] = deviceCalnEdgePoint(volume, x + 0, y + 0, z + 1, 1, 0, 0);
			pos[5] = deviceCalnEdgePoint(volume, x + 1, y + 0, z + 1, 0, 1, 0);
			pos[6] = deviceCalnEdgePoint(volume, x + 0, y + 1, z + 1, 1, 0, 0);
			pos[7] = deviceCalnEdgePoint(volume, x + 0, y + 0, z + 1, 0, 1, 0);

			pos[8] = deviceCalnEdgePoint(volume, x + 0, y + 0, z + 0, 0, 0, 1);
			pos[9] = deviceCalnEdgePoint(volume, x + 1, y + 0, z + 0, 0, 0, 1);
			pos[10] = deviceCalnEdgePoint(volume, x + 1, y + 1, z + 0, 0, 0, 1);
			pos[11] = deviceCalnEdgePoint(volume, x + 0, y + 1, z + 0, 0, 0, 1);

			for (int i = 0; i < 5 && triTable_device[cubeId][i * 3] != -1; i++) {
				for (int j = 0; j < 3; j++) {
					int edgeId = triTable_device[cubeId][i * 3 + j];
					posBuffer[j] = pos[edgeId] * volumeSize + offset;
				}
				posBuffer[3] = (posBuffer[0] + posBuffer[1]) * 0.5;
				posBuffer[4] = (posBuffer[1] + posBuffer[2]) * 0.5;
				posBuffer[5] = (posBuffer[2] + posBuffer[0]) * 0.5;
				for (int j = 0; j < 3; j++) {
					vtx->pos = posBuffer[j];
					vtx->color = calnColor(cameras, volumeBin[id], posBuffer[j], transformation, intrinsics, colorMap);
					vtx->color2 = calnColor(cameras, volumeBin[id], posBuffer[j + 3], transformation, intrinsics, colorMap);
					vtx++;
				}
			}
		}
	}
}

__global__ void cudaCountAccumulation(int *count_device, int *sum_device, int *temp_device) {//һ��block��1024���̣߳�����2048������һ����Ҫ����resx*resy = 2^18�������ֳ�128��block��
	int block_offset = blockIdx.x * 2048;//ȷ������ڼ���2048��
	int thid = threadIdx.x;

	__shared__ int shared_count_device[2048];
	if (block_offset == 0 && thid == 0)
		shared_count_device[0] = 0;
	else
		shared_count_device[2 * thid] = count_device[block_offset + 2 * thid - 1];
	shared_count_device[2 * thid + 1] = count_device[block_offset + 2 * thid];
	__syncthreads();//shared��ֵ��Ҫͬ����

	//UpSweep
	int offset = 1;
	int n = 2048;
	for (int d = n >> 1; d > 0; d >>= 1)                    // build sum in place up the tree
	{
		__syncthreads();
		if (thid < d)
		{
			int ai = offset*(2 * thid + 1) - 1;
			int bi = offset*(2 * thid + 2) - 1;
			shared_count_device[bi] += shared_count_device[ai];
		}
		offset *= 2;
	}

	//DownSweep,ע��������ΪҪ������block����ͣ�����ʹ�õ���inclusive scan��
	for (int i = n / 2; i > 1; i /= 2) {
		__syncthreads();
		int start = (i - 1) + (i >> 1);
		int doffset = (i >> 1);
		if ((2 * thid - start) % i == 0 && 2 * thid - start >= 0) {
			shared_count_device[2 * thid] += shared_count_device[2 * thid - doffset];
		}
		if ((2 * thid + 1 - start) % i == 0 && 2 * thid + 1 - start >= 0) {
			shared_count_device[2 * thid + 1] += shared_count_device[2 * thid + 1 - doffset];
		}
	}
	temp_device[block_offset + 2 * thid] = shared_count_device[2 * thid];
	temp_device[block_offset + 2 * thid + 1] = shared_count_device[2 * thid + 1];
	if (thid == 0) {
		sum_device[blockIdx.x] = shared_count_device[n - 1];
	}
}

__global__ void cudaCountAccumulation2(int *count_device, int *sum_device, int *temp_device) {//һ��block��1024���̣߳�����2048������һ����Ҫ����resx*resy = 2^18�������ֳ�128��block��
	int block_offset = blockIdx.x * 2048;//ȷ������ڼ���2048��
	int thid = threadIdx.x;
	int n = 2048;
	__shared__ int shared_count_device[2048];
	__shared__ int presum;
	shared_count_device[2 * thid] = temp_device[block_offset + 2 * thid];
	shared_count_device[2 * thid + 1] = temp_device[block_offset + 2 * thid + 1];
	if (thid == 0) {
		if (blockIdx.x != 0) {
			presum = sum_device[blockIdx.x - 1];
		}
		else {
			presum = 0;
		}
	}
	__syncthreads();//shared��ֵ��Ҫͬ����

	shared_count_device[2 * thid] += presum;
	shared_count_device[2 * thid + 1] += presum;

	count_device[block_offset + 2 * thid] = shared_count_device[2 * thid];
	count_device[block_offset + 2 * thid + 1] = shared_count_device[2 * thid + 1];
}

int cpu_cudaCountAccumulation() {
	const int DATASIZE = VOLUME * VOLUME;
	int threads = 1024;
	int blocks = DATASIZE / threads / 2;
	int sum_host[128];
	int* sum_device;
	int* temp_device;
	HANDLE_ERROR(cudaMalloc(&sum_device, blocks * sizeof(int)));
	HANDLE_ERROR(cudaMalloc(&temp_device, DATASIZE * sizeof(int)));
	//stage1
	cudaCountAccumulation << <blocks, threads >> > (count_device, sum_device, temp_device);
	HANDLE_ERROR(cudaGetLastError());
	HANDLE_ERROR(cudaMemcpy(sum_host, sum_device, blocks * sizeof(int), cudaMemcpyDeviceToHost));
	for (int i = 1; i < blocks; ++i) {
		sum_host[i] += sum_host[i - 1];
	}
	//stage2
	HANDLE_ERROR(cudaMemcpy(sum_device, sum_host, blocks * sizeof(int), cudaMemcpyHostToDevice));
	cudaCountAccumulation2 << <blocks, threads >> > (count_device, sum_device, temp_device);
	HANDLE_ERROR(cudaGetLastError());

	HANDLE_ERROR(cudaFree(sum_device));
	HANDLE_ERROR(cudaFree(temp_device));
	int tris_size = sum_host[blocks - 1];
	return tris_size;
}

extern "C"
void cudaIntegrate(int cameras, int& triSize, Vertex* vertex, UINT16** depth, float* depth_device, RGBQUAD** color, Transformation* depthTrans, Transformation* colorTrans, Intrinsics* depthIntrinsics, Intrinsics* colorIntrinsics) {
	dim3 blocks = dim3(VOLUME / BLOCK_SIZE, VOLUME / BLOCK_SIZE);
	dim3 threads = dim3(BLOCK_SIZE, BLOCK_SIZE);

	HANDLE_ERROR(cudaMemcpy(depthTrans_device, depthTrans, MAX_CAMERAS * sizeof(Transformation), cudaMemcpyHostToDevice));
	HANDLE_ERROR(cudaMemcpy(depthIntrinsics_device, depthIntrinsics, MAX_CAMERAS * sizeof(Intrinsics), cudaMemcpyHostToDevice));
	/*for (int i = 0; i < cameras; i++) {
		if (depth[i] != NULL) {
			HANDLE_ERROR(cudaMemcpy(depth_device + i * DEPTH_W * DEPTH_H, depth[i], DEPTH_W * DEPTH_H * sizeof(UINT16), cudaMemcpyHostToDevice));
		}
	}*/

	HANDLE_ERROR(cudaMemcpyAsync(colorTrans_device, colorTrans, MAX_CAMERAS * sizeof(Transformation), cudaMemcpyHostToDevice));
	HANDLE_ERROR(cudaMemcpyAsync(colorIntrinsics_device, colorIntrinsics, MAX_CAMERAS * sizeof(Intrinsics), cudaMemcpyHostToDevice));
	for (int i = 0; i < cameras; i++) {
		if (color[i] != NULL) {
			HANDLE_ERROR(cudaMemcpyAsync(color_device + i * COLOR_W * COLOR_H, color[i], COLOR_W * COLOR_H * sizeof(uchar4), cudaMemcpyHostToDevice));
		}
	}

	kernelIntegrateDepth << <blocks, threads >> > (cameras, volume_device, volumeBin_device, depthTrans_device, depthIntrinsics_device, depth_device, volumeSize, offset); //1.7ms
	HANDLE_ERROR(cudaGetLastError());

	kernelMarchingCubesCount << <blocks, threads >> > (volume_device, count_device);
	HANDLE_ERROR(cudaGetLastError());
	triSize = cpu_cudaCountAccumulation();

	if (triSize * 3 <= MAX_VERTEX) {
		kernelMarchingCubes << <blocks, threads >> > (cameras, volume_device, volumeBin_device, count_device, vertex_device, colorTrans_device, colorIntrinsics_device, color_device, volumeSize, offset); //3.6ms
		HANDLE_ERROR(cudaGetLastError());
		HANDLE_ERROR(cudaMemcpy(vertex, vertex_device, triSize * 3 * sizeof(Vertex), cudaMemcpyDeviceToHost));
	} else {
		std::cout << "vertex size limit exceeded" << std::endl;
	}
}
