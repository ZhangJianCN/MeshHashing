//
// Created by wei on 17-3-13.
//

#ifndef MRF_VH_TEST_HASH_DATA_H
#define MRF_VH_TEST_HASH_DATA_H

#include "hash_table.h"

class TestHashData {
public:
  __host__ void Run(HashData &hash_data, int3 pos);
};

#endif //MRF_VH_TEST_HASH_DATA_H
