#import <Foundation/Foundation.h>
#include "spi/VTVideoDecoderSPI.h"
#include <stddef.h>
int main(){
    printf("{\"versionBytes\":%zu,\"baseBytes\":%zu,\"derivedStorageOffset\":%zu,\"decoderClassBytes\":%zu,\"decoderStartOffset\":%zu}\n",
        sizeof(CMBaseClassVersion),sizeof(CMBaseClass),offsetof(CMBaseClass,derivedStorageSize),sizeof(VTVideoDecoderClass),offsetof(VTVideoDecoderClass,startSession));
    return 0;
}
