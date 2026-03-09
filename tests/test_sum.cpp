#include <gtest/gtest.h>

extern "C" {
#include "webwrap/webwrap.h"
}

TEST(WebWrapTest, SumAddsTwoIntegers) {
    EXPECT_EQ(ww_sum(2, 3), 5);
}

TEST(WebWrapTest, SumHandlesNegativeValues) {
    EXPECT_EQ(ww_sum(-2, 3), 1);
}
