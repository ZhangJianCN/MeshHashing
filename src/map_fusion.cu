#include <device_launch_parameters.h>
#include "map.h"
#include "sensor.h"
#include "gradient.h"

#ifndef PINF
#define PINF  __int_as_float(0x7f800000)
#endif

/// Refer to sensor.cu
extern texture<float,  cudaTextureType2D, cudaReadModeElementType> depth_texture;
extern texture<float4, cudaTextureType2D, cudaReadModeElementType> color_texture;

////////////////////
/// class Map - integrate sensor data
////////////////////

////////////////////
/// Device code
////////////////////
__global__
void UpdateBlocksKernel(CompactHashTableGPU compact_hash_table,
                        HashTableGPU        hash_table,
                        BlocksGPU           blocks,
                        MeshGPU             mesh,
                        SensorDataGPU       sensor_data,
                        SensorParams        sensor_params,
                        float4x4            c_T_w) {

  //TODO check if we should load this in shared memory (compacted_entries)
  /// 1. Select voxel
  const HashEntry &entry = compact_hash_table.compacted_entries[blockIdx.x];
  int3 voxel_base_pos = BlockToVoxel(entry.pos);
  uint local_idx = threadIdx.x;  //inside of an SDF block
  int3 voxel_pos = voxel_base_pos + make_int3(IdxToVoxelLocalPos(local_idx));

  Voxel& this_voxel = blocks[entry.ptr].voxels[local_idx];
  /// 2. Project to camera
  float3 world_pos = VoxelToWorld(voxel_pos);
  float3 camera_pos = c_T_w * world_pos;
  uint2 image_pos = make_uint2(
          CameraProjectToImagei(camera_pos,
                                sensor_params.fx, sensor_params.fy,
                                sensor_params.cx, sensor_params.cy));
  if (image_pos.x >= sensor_params.width
      || image_pos.y >= sensor_params.height)
    return;

  /// 3. Find correspondent depth observation
  float depth = tex2D(depth_texture, image_pos.x, image_pos.y);
  if (depth == MINF || depth == 0.0f || depth >= kSDFParams.sdf_upper_bound)
    return;

  /// 4. SDF computation
  float3 dp = ImageReprojectToCamera(image_pos.x, image_pos.y, depth,
      sensor_params.fx, sensor_params.fy, sensor_params.cx, sensor_params.cy);
  float3 dpw = c_T_w.getInverse() * dp;

  /// Solve (I + \sum \lambda nn^T + ... )x = (dp + \sum \lambda nn^Tv)
  float3x3 A = float3x3::getIdentity();
  float3   b = dpw;
  float wd = (1.0f - NormalizeDepth(depth,
                                   sensor_params.min_depth_range,
                                   sensor_params.max_depth_range));
  float wn = 0.5f;
  bool addition = false;
  for (int i = 0; i < N_VERTEX; ++i) {
    if (this_voxel.vertex_ptrs[i] > 0) {
      addition = true;
      Vertex vtx = mesh.vertices[this_voxel.vertex_ptrs[i]];
      float3 v = vtx.pos;
      float3 n = vtx.normal;
      wn += dot(c_T_w * n, normalize(-dp));
      float3x3 nnT = float3x3(n.x*n.x, n.x*n.y, n.x*n.z,
                              n.y*n.x, n.y*n.y, n.y*n.z,
                              n.z*n.x, n.z*n.y, n.z*n.z);

      float dist = length(dpw - v);
      float wdist = dist / kSDFParams.voxel_size;
      float ww = expf(- wdist*wdist);
      A = A + nnT * ww;
      b = b + nnT * v * ww;
    }
  }

  // Best estimation for dp
  if (addition) {
    dpw = A.getInverse() * b;
  }
  dp = c_T_w * dpw;
  //float3 np = normalize(-dp);

  //printf("%f %f %f\n", np.x, np.y, np.z)
  //
  float sdf = dot(normalize(-dp), camera_pos - dp);
  //float sdf = depth - camera_pos.z;
  //uchar weight = (uchar)fmax(1.0f, kSDFParams.weight_sample * wn * wd);

  uchar weight = (uchar)fmax(kSDFParams.weight_sample * 1.5f *
                     (1.0f - NormalizeDepth(depth,
                                            sensor_params.min_depth_range,
                                            sensor_params.max_depth_range)),
                     1.0f);
  float truncation = truncate_distance(depth);
  if (sdf <= -truncation)
    return;
  if (sdf >= 0.0f) {
    sdf = fminf(truncation, sdf);
  } else {
    sdf = fmaxf(-truncation, sdf);
  }

  /// 5. Update
  Voxel delta;
  delta.sdf = sdf;
  delta.weight = weight;

  if (sensor_data.color_image) {
    float4 color = tex2D(color_texture, image_pos.x, image_pos.y);
    delta.color = make_uchar3(255 * color.x, 255 * color.y, 255 * color.z);
  } else {
    delta.color = make_uchar3(0, 255, 0);
  }
  this_voxel.Update(delta);
}

__global__
void AllocBlocksKernel(HashTableGPU   hash_table,
                       SensorDataGPU  sensor_data,
                       SensorParams   sensor_params,
                       float4x4       w_T_c,
                       const uint* is_streamed_mask) {

  const uint x = blockIdx.x * blockDim.x + threadIdx.x;
  const uint y = blockIdx.y * blockDim.y + threadIdx.y;

  if (x >= sensor_params.width || y >= sensor_params.height)
    return;

  /// TODO(wei): change it here
  /// 1. Get observed data
  float depth = tex2D(depth_texture, x, y);
  if (depth == MINF || depth == 0.0f
      || depth >= kSDFParams.sdf_upper_bound)
    return;

  float truncation = truncate_distance(depth);
  float near_depth = fminf(kSDFParams.sdf_upper_bound, depth - truncation);
  float far_depth = fminf(kSDFParams.sdf_upper_bound, depth + truncation);
  if (near_depth >= far_depth) return;

  float3 camera_pos_near = ImageReprojectToCamera(x, y, near_depth,
                                                  sensor_params.fx, sensor_params.fy,
                                                  sensor_params.cx, sensor_params.cy);
  float3 camera_pos_far  = ImageReprojectToCamera(x, y, far_depth,
                                                  sensor_params.fx, sensor_params.fy,
                                                  sensor_params.cx, sensor_params.cy);

  /// 2. Set range where blocks are allocated
  float3 world_pos_near  = w_T_c * camera_pos_near;
  float3 world_pos_far   = w_T_c * camera_pos_far;
  float3 world_ray_dir = normalize(world_pos_far - world_pos_near);

  int3 block_pos_near = WorldToBlock(world_pos_near);
  int3 block_pos_far  = WorldToBlock(world_pos_far);
  float3 block_step = make_float3(sign(world_ray_dir));

  /// 3. Init zig-zag steps
  float3 world_pos_nearest_voxel_center
          = BlockToWorld(block_pos_near + make_int3(clamp(block_step, 0.0, 1.0f)))
            - 0.5f * kSDFParams.voxel_size;
  float3 t = (world_pos_nearest_voxel_center - world_pos_near) / world_ray_dir;
  float3 dt = (block_step * BLOCK_SIDE_LENGTH * kSDFParams.voxel_size) / world_ray_dir;
  int3 block_pos_bound = make_int3(make_float3(block_pos_far) + block_step);

  if (world_ray_dir.x == 0.0f) {
    t.x = PINF;
    dt.x = PINF;
  }
  if (world_ray_dir.y == 0.0f) {
    t.y = PINF;
    dt.y = PINF;
  }
  if (world_ray_dir.z == 0.0f) {
    t.z = PINF;
    dt.z = PINF;
  }

  int3 block_pos_curr = block_pos_near;
  /// 4. Go a zig-zag path to ensure all voxels are visited
  const uint kMaxIterTime = 1024;
#pragma unroll 1
  for (uint iter = 0; iter < kMaxIterTime; ++iter) {
    if (IsBlockInCameraFrustum(w_T_c.getInverse(), block_pos_curr, sensor_params)) {
      /// Disable streaming at current
      // && !isSDFBlockStreamedOut(idCurrentVoxel, hash_table, is_streamed_mask)) {
      hash_table.AllocEntry(block_pos_curr);
    }

    // Traverse voxel grid
    if (t.x < t.y && t.x < t.z) {
      block_pos_curr.x += block_step.x;
      if (block_pos_curr.x == block_pos_bound.x) return;
      t.x += dt.x;
    } else if (t.y < t.z) {
      block_pos_curr.y += block_step.y;
      if (block_pos_curr.y == block_pos_bound.y) return;
      t.y += dt.y;
    } else {
      block_pos_curr.z += block_step.z;
      if (block_pos_curr.z == block_pos_bound.z) return;
      t.z += dt.z;
    }
  }
}


////////////////////
/// Host code
////////////////////
void Map::Integrate(Sensor& sensor) {
  AllocBlocks(sensor);

  CollectInFrustumBlocks(sensor);
  UpdateBlocks(sensor);

  Recycle(integrated_frame_count_);
  integrated_frame_count_ ++;
}

void Map::AllocBlocks(Sensor& sensor) {
  hash_table_.ResetMutexes();

  const uint threads_per_block = 8;
  const dim3 grid_size((sensor.sensor_params().width + threads_per_block - 1)
                       /threads_per_block,
                       (sensor.sensor_params().height + threads_per_block - 1)
                       /threads_per_block);
  const dim3 block_size(threads_per_block, threads_per_block);

  AllocBlocksKernel<<<grid_size, block_size>>>(
          hash_table_.gpu_data(),
          sensor.gpu_data(),
          sensor.sensor_params(), sensor.w_T_c(),
          NULL);

  checkCudaErrors(cudaDeviceSynchronize());
  checkCudaErrors(cudaGetLastError());
}

void Map::UpdateBlocks(Sensor &sensor) {
  const uint threads_per_block = BLOCK_SIZE;

  uint compacted_entry_count = compact_hash_table_.entry_count();
  if (compacted_entry_count <= 0)
    return;

  const dim3 grid_size(compacted_entry_count, 1);
  const dim3 block_size(threads_per_block, 1);
  UpdateBlocksKernel <<<grid_size, block_size>>>(
          compact_hash_table_.gpu_data(),
          hash_table_.gpu_data(),
          blocks_.gpu_data(),
          mesh_.gpu_data(),
          sensor.gpu_data(),
          sensor.sensor_params(), sensor.c_T_w());
  checkCudaErrors(cudaDeviceSynchronize());
  checkCudaErrors(cudaGetLastError());
}