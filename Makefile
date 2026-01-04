CC ?= cc
CFLAGS ?= -O2 -fPIC -Wall -Wextra
LDFLAGS ?= -shared
BQN ?= cbqn

TARGET := libtensorscan.so
SRC := src/tensorscan.c

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

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
