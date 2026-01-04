CC ?= cc
CFLAGS ?= -O2 -fPIC -Wall -Wextra
LDFLAGS ?= -shared
BQN ?= cbqn

TARGET := libtensorscan.so
SRC_COMMON := src/ffi_layer.c

UNAME := $(shell uname)
ifeq ($(UNAME), Linux)
    SRC_DRIVER := src/driver_linux.c
else
    $(error "OS not supported yet")
endif

all: $(TARGET)

$(TARGET): $(SRC_COMMON) $(SRC_DRIVER)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^

run: $(TARGET)
	@command -v $(BQN) >/dev/null 2>&1 || { \
		echo "TensorScan: BQN executable '$(BQN)' not found. Set BQN=/path/to/cbqn."; \
		exit 1; \
	}
	$(BQN) lib/demo.bqn

validate: $(TARGET)
	@command -v $(BQN) >/dev/null 2>&1 || { \
		echo "TensorScan: BQN executable '$(BQN)' not found. Set BQN=/path/to/cbqn."; \
		exit 1; \
	}
	$(BQN) lib/validate.bqn

clean:
	rm -f $(TARGET)

.PHONY: all run validate clean
