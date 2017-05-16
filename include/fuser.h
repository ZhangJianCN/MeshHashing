//
// Created by wei on 17-3-16.
//

#ifndef VH_MAPPER_H
#define VH_MAPPER_H

#include "common.h"

#include "geometry_util.h"
#include "params.h"
#include "hash_table_gpu.h"
#include "map.h"
#include "mesh.h"
#include "sensor.h"

class Fuser {
private:
  void UpdateBlocks(Map* map, Sensor* sensor);
  void AllocBlocks(Map* map, Sensor* sensor);
  void CollectTargetBlocks(Map* map, Sensor *sensor);

public:
  Fuser();
  ~Fuser();

  void Integrate(Map* map, Sensor *sensor, unsigned int* is_streamed_mask);
};

#endif //VH_MAPPER_H
