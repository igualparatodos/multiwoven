import { Box, FormControl, FormLabel, Radio, RadioGroup, Select, Stack, Text } from '@chakra-ui/react';
import { Dispatch, SetStateAction } from 'react';
import { Stream, UniqueIdentifierConfig } from '@/views/Activate/Syncs/types';
import { RJSFSchema } from '@rjsf/utils';

type OperationTypeSelectorProps = {
  selectedDestinationSyncMode: string;
  setSelectedDestinationSyncMode: Dispatch<SetStateAction<string>>;
  uniqueIdentifierConfig: UniqueIdentifierConfig | null;
  setUniqueIdentifierConfig: Dispatch<SetStateAction<UniqueIdentifierConfig | null>>;
  selectedStream: Stream | null;
  destinationName?: string;
};

const OperationTypeSelector = ({
  selectedDestinationSyncMode,
  setSelectedDestinationSyncMode,
  uniqueIdentifierConfig,
  setUniqueIdentifierConfig,
  selectedStream,
  destinationName,
}: OperationTypeSelectorProps): JSX.Element => {
  const isAirtable = destinationName?.toLowerCase().includes('airtable');

  // Only show for Airtable destinations
  if (!isAirtable) {
    return <></>;
  }

  // Get destination fields from stream schema
  const destinationFields: string[] = [];
  if (selectedStream?.json_schema) {
    const properties = (selectedStream.json_schema as RJSFSchema).properties || {};
    Object.keys(properties).forEach((key) => {
      destinationFields.push(key);
    });
  }

  const needsUniqueIdentifier = selectedDestinationSyncMode === 'destination_upsert' || selectedDestinationSyncMode === 'destination_update';

  const handleOperationTypeChange = (value: string) => {
    setSelectedDestinationSyncMode(value);
    // Clear unique identifier if switching to insert
    if (value === 'destination_insert') {
      setUniqueIdentifierConfig(null);
    }
  };

  const handleUniqueFieldChange = (destinationField: string) => {
    setUniqueIdentifierConfig({
      source_field: destinationField, // Will be mapped in field mappings
      destination_field: destinationField,
    });
  };

  return (
    <Box mb={6} mt={6}>
      <FormControl>
        <FormLabel fontSize='sm' fontWeight='semibold' mb={3}>
          Operation Type
        </FormLabel>
        <RadioGroup onChange={handleOperationTypeChange} value={selectedDestinationSyncMode}>
          <Stack direction='column' spacing={3}>
            <Radio value='destination_insert' colorScheme='purple'>
              <Box>
                <Text fontWeight='medium'>Create only (Insert)</Text>
                <Text fontSize='sm' color='gray.600'>
                  Always create new records in Airtable. May create duplicates on re-sync.
                </Text>
              </Box>
            </Radio>
            <Radio value='destination_upsert' colorScheme='purple'>
              <Box>
                <Text fontWeight='medium'>Create or Update (Upsert)</Text>
                <Text fontSize='sm' color='gray.600'>
                  Update existing records or create new ones. Requires a unique identifier field.
                </Text>
              </Box>
            </Radio>
            <Radio value='destination_update' colorScheme='purple'>
              <Box>
                <Text fontWeight='medium'>Update only</Text>
                <Text fontSize='sm' color='gray.600'>
                  Only update existing records. Records not found will fail. Requires a unique identifier field.
                </Text>
              </Box>
            </Radio>
          </Stack>
        </RadioGroup>
      </FormControl>

      {needsUniqueIdentifier && selectedStream && (
        <Box mt={6} p={4} bg='blue.50' borderRadius='md' border='1px' borderColor='blue.200'>
          <FormControl isRequired>
            <FormLabel fontSize='sm' fontWeight='semibold' mb={2}>
              Unique Identifier Field
            </FormLabel>
            <Text fontSize='sm' color='gray.700' mb={3}>
              Select the Airtable field that uniquely identifies records (e.g., Email, ID, External ID).
            </Text>
            <Select
              placeholder='Select unique identifier field'
              value={uniqueIdentifierConfig?.destination_field || ''}
              onChange={(e) => handleUniqueFieldChange(e.target.value)}
              bg='white'
            >
              {destinationFields.map((field) => (
                <option key={field} value={field}>
                  {field}
                </option>
              ))}
            </Select>
            {!uniqueIdentifierConfig?.destination_field && (
              <Text fontSize='xs' color='red.500' mt={2}>
                Required: You must select a unique identifier field for {selectedDestinationSyncMode} operations
              </Text>
            )}
          </FormControl>
        </Box>
      )}
    </Box>
  );
};

export default OperationTypeSelector;
