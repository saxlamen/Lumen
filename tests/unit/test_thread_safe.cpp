/**
 * @file tests/unit/test_thread_safe.cpp
 * @brief Tests for thread-safe utility types.
 */

// standard includes
#include <cstdint>
#include <type_traits>

// lib includes
#include <gtest/gtest.h>

// local includes
#include "src/thread_safe.h"

static_assert(!std::is_convertible_v<std::uint32_t, safe::queue_t<int>>);

TEST(ThreadSafeQueue, RejectsNewestItemAtCapacity) {
  safe::queue_t<int> queue {1, safe::queue_t<int>::overflow_policy_e::reject};

  ASSERT_TRUE(queue.raise(1));
  EXPECT_FALSE(queue.raise(2));

  const auto value = queue.pop();
  ASSERT_TRUE(value);
  EXPECT_EQ(*value, 1);
}

TEST(ThreadSafeQueue, DropsQueuedItemsByDefaultAtCapacity) {
  safe::queue_t<int> queue {2};

  ASSERT_TRUE(queue.raise(1));
  ASSERT_TRUE(queue.raise(2));
  ASSERT_TRUE(queue.raise(3));

  const auto value = queue.pop();
  ASSERT_TRUE(value);
  EXPECT_EQ(*value, 3);
}

TEST(ThreadSafeQueue, RejectsItemsAfterStop) {
  safe::queue_t<int> queue;

  queue.stop();

  EXPECT_FALSE(queue.raise(1));
}

/**
 * @brief drop_one_oldest keeps the newest backlog intact instead of emptying the queue.
 */
TEST(ThreadSafeQueue, DropsOnlyOldestAtCapacity) {
  safe::queue_t<int> queue {2, safe::queue_t<int>::overflow_policy_e::drop_one_oldest};

  ASSERT_TRUE(queue.raise(1));
  ASSERT_TRUE(queue.raise(2));
  ASSERT_TRUE(queue.raise(3));

  const auto first = queue.pop();
  ASSERT_TRUE(first);
  EXPECT_EQ(*first, 2);

  const auto second = queue.pop();
  ASSERT_TRUE(second);
  EXPECT_EQ(*second, 3);
}

/**
 * @brief Every policy accounts for the items it discards.
 */
TEST(ThreadSafeQueue, CountsDiscardedItemsPerPolicy) {
  safe::queue_t<int> drop_one {2, safe::queue_t<int>::overflow_policy_e::drop_one_oldest};
  drop_one.raise(1);
  drop_one.raise(2);
  drop_one.raise(3);
  EXPECT_EQ(drop_one.overflow_count(), 1U);

  // The default policy discards the whole backlog that was queued
  safe::queue_t<int> drop_all {2};
  drop_all.raise(1);
  drop_all.raise(2);
  drop_all.raise(3);
  EXPECT_EQ(drop_all.overflow_count(), 2U);

  // reject discards the incoming item
  safe::queue_t<int> rejected {1, safe::queue_t<int>::overflow_policy_e::reject};
  rejected.raise(1);
  rejected.raise(2);
  EXPECT_EQ(rejected.overflow_count(), 1U);
}

/**
 * @brief Staying below the bound discards nothing.
 */
TEST(ThreadSafeQueue, NoDiscardsBelowBound) {
  safe::queue_t<int> queue {3, safe::queue_t<int>::overflow_policy_e::drop_one_oldest};

  queue.raise(1);
  queue.raise(2);
  queue.raise(3);

  EXPECT_EQ(queue.overflow_count(), 0U);
  EXPECT_TRUE(queue.peek());
}
