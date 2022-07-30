#include <stdint.h>
#include <crucible.h>

int main() {
  int32_t x = crucible_int32_t("x");
  int32_t y = crucible_int32_t("y");
  int32_t z = crucible_int32_t("z");
  assuming(y > 0);
  check(x + y + z > 0);
  return 0;
}