CC      ?= gcc
CFLAGS  := -shared -fPIC -Wall -Wextra -O2
LDFLAGS := -ldl
TARGET  := steam_cef_gpu_fix.so
SRC     := steam_cef_gpu_fix.c

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f $(TARGET)
