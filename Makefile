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
	$(BQN) lib/demo.bqn

validate: $(TARGET)
	$(BQN) lib/validate.bqn

clean:
	rm -f $(TARGET)

.PHONY: all run validate clean
